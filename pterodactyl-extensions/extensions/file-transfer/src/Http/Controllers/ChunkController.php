<?php

declare(strict_types=1);

namespace FileTransfer\Http\Controllers;

use FileTransfer\Support\ChunkStore;
use FileTransfer\Support\ChunkValidator;
use FileTransfer\Support\FileTransferSettings;
use FileTransfer\Support\PathValidator;
use FileTransfer\Support\WingsFileService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use Pterodactyl\Models\Server;
use Throwable;

/**
 * Upload in pieces: the browser cuts a file into chunks, sends them one by one, then asks for them to be merged and
 * handed to the server. Both routes need the Panel's own `file.create` permission (the Panel only proves the user
 * may open the server). Errors are answered with a fixed code and, for a merge, the list of what is missing.
 */
final class ChunkController
{
    public function __construct(
        private readonly ChunkStore $store,
        private readonly FileTransferSettings $settings,
        private readonly WingsFileService $wings,
    ) {}

    public function chunk(Request $request, Server $server): JsonResponse
    {
        abort_unless($request->user()->can('file.create', $server), 403);

        $input = $request->validate([
            'upload_id' => ['required', 'string', 'max:36'],
            'index' => ['required', 'integer'],
            'total_chunks' => ['required', 'integer'],
            'filename' => ['required', 'string', 'max:255'],
            'checksum' => ['required', 'string', 'max:64'],
            // "present", not "required", and "nullable": an empty file makes an empty chunk, and the Panel turns an
            // empty string into null before validation (EC-FT12).
            'data' => ['present', 'nullable', 'string'],
        ]);

        $error = ChunkValidator::validate($input['upload_id'], $input['index'], $input['total_chunks'], $input['filename'], $input['checksum']);
        if ($error !== null) {
            return $this->fail($error);
        }

        // A file that can never fit is refused before its first piece is written, not after the disk is full.
        $chunkBytes = $this->settings->chunkSizeMb() * 1048576;
        if ($input['total_chunks'] > (int) ceil($this->settings->maxFileMb() / $this->settings->chunkSizeMb())) {
            return $this->fail('file_too_large');
        }

        $bytes = base64_decode($input['data'] ?? '', true);
        if ($bytes === false) {
            return $this->fail('invalid_chunk_data');
        }
        if (strlen($bytes) > $chunkBytes) {
            return $this->fail('chunk_too_large');
        }
        if (! hash_equals(strtolower($input['checksum']), hash('sha256', $bytes))) {
            return $this->fail('checksum_mismatch');
        }

        if ($this->store->claim($input['upload_id'], $server->uuid, $input['filename'], $input['total_chunks']) !== null) {
            return $this->fail('upload_id_conflict');
        }

        $this->store->store($input['upload_id'], $input['index'], $bytes);

        return response()->json([
            'accepted' => $input['index'],
            'remaining' => count($this->store->missing($input['upload_id'], $input['total_chunks'])),
        ]);
    }

    public function merge(Request $request, Server $server): JsonResponse
    {
        abort_unless($request->user()->can('file.create', $server), 403);

        $input = $request->validate([
            'upload_id' => ['required', 'string', 'max:36'],
            'filename' => ['required', 'string', 'max:255'],
            'target_directory' => ['required', 'string', 'max:255'],
            'total_checksum' => ['required', 'string', 'max:64'],
        ]);

        if (! ChunkValidator::validUploadId($input['upload_id'])) {
            return $this->fail('invalid_upload_id');
        }
        if (! ChunkValidator::validateFilename($input['filename'])) {
            return $this->fail('invalid_filename');
        }
        if (! ChunkValidator::validChecksum($input['total_checksum'])) {
            return $this->fail('invalid_checksum');
        }
        if (($pathError = PathValidator::validate($input['target_directory'])) !== null) {
            return $this->fail($pathError);
        }

        // What this upload is (its total, its file name, its server) was fixed by its first chunk, not by this request.
        $meta = $this->store->meta($input['upload_id']);
        if ($meta === null || $meta['server'] !== $server->uuid) {
            return $this->fail('upload_not_found', 404);
        }
        if ($meta['filename'] !== $input['filename']) {
            return $this->fail('upload_id_conflict');
        }

        // Two merges of one upload would write the same file at the same time.
        $lock = Cache::lock("file-transfer:merge:{$input['upload_id']}", 3600);
        if (! $lock->get()) {
            return $this->fail('merge_in_progress', 409);
        }

        try {
            return $this->mergeAndUpload($server, $input, $meta['total_chunks']);
        } finally {
            $lock->release();
        }
    }

    /** @param  array{upload_id: string, filename: string, target_directory: string, total_checksum: string}  $input */
    private function mergeAndUpload(Server $server, array $input, int $totalChunks): JsonResponse
    {
        $missing = $this->store->missing($input['upload_id'], $totalChunks);
        if ($missing !== []) {
            return response()->json(['error' => 'chunks_missing', 'missing' => $missing], 422);
        }

        // The size is known from the pieces already on disk, so a file that is too big is never assembled (FR-FT6).
        if ($this->store->receivedBytes($input['upload_id'], $totalChunks) > $this->settings->maxFileMb() * 1048576) {
            return $this->fail('file_too_large');
        }

        $merged = $this->store->mergedPath($input['upload_id'], $input['filename']);

        try {
            $this->store->mergeTo($input['upload_id'], $totalChunks, $merged);

            if (! hash_equals(strtolower($input['total_checksum']), (string) hash_file('sha256', $merged))) {
                return $this->fail('checksum_mismatch');
            }

            $this->wings->upload($server->uuid, $merged, PathValidator::join($input['target_directory'], $input['filename']));
        } catch (Throwable $exception) {
            Log::warning('file-transfer: merged upload failed', ['server' => $server->id, 'upload' => $input['upload_id'], 'error' => $exception::class]);

            return $this->fail('upload_failed', 503);
        } finally {
            $this->store->deleteMerged($input['upload_id']);
        }

        $this->store->delete($input['upload_id']);

        return response()->json(['uploaded' => true]);
    }

    private function fail(string $code, int $status = 422): JsonResponse
    {
        return response()->json(['error' => $code], $status);
    }
}
