<?php

declare(strict_types=1);

namespace FileTransfer\Http\Controllers;

use FileTransfer\Jobs\FetchRemoteFile;
use FileTransfer\Support\ChunkValidator;
use FileTransfer\Support\PathValidator;
use FileTransfer\Support\RemoteUrlValidator;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionJobProgress;

/**
 * Starts a download from a URL to a server. Nothing is downloaded in the request: it checks what can be checked
 * without the network, opens a progress record the browser can follow, queues the job, and answers 202 (FR-FT9).
 */
final class RemoteFetchController
{
    public function __construct(private readonly ExtensionJobProgress $progress) {}

    public function fetch(Request $request, Server $server): JsonResponse
    {
        abort_unless($request->user()->can('ext.file-transfer.remote-fetch', $server), 403);

        $input = $request->validate([
            'url' => ['required', 'string', 'max:2048'],
            'target_directory' => ['required', 'string', 'max:255'],
            'filename' => ['nullable', 'string', 'max:255'],
        ]);

        if (($error = RemoteUrlValidator::validate($input['url'])) !== null) {
            return response()->json(['error' => $error], 422);
        }
        if (($error = PathValidator::validate($input['target_directory'])) !== null) {
            return response()->json(['error' => $error], 422);
        }

        $filename = ($input['filename'] ?? '') !== '' ? $input['filename'] : self::filenameFrom($input['url']);
        if (! ChunkValidator::validateFilename($filename)) {
            return response()->json(['error' => 'invalid_filename'], 422);
        }

        // The id the browser follows is the progress record's own, and only someone who may fetch can read it.
        $job = $this->progress->begin('file-transfer', $request->user(), $server, 'ext.file-transfer.remote-fetch');

        DB::afterCommit(fn () => FetchRemoteFile::dispatchSafely($server->uuid, $input['url'], $input['target_directory'], $filename, $job->id));

        return response()->json(['job_id' => $job->id], 202);
    }

    /** The last part of the URL's path, cut down to safe characters; "downloaded_file" when nothing is left (EC-FT10). */
    private static function filenameFrom(string $url): string
    {
        // Decode first, then take the last segment: "%2e%2e%2fpasswd" is "../passwd", whose last segment is "passwd".
        $name = basename(rawurldecode((string) parse_url($url, PHP_URL_PATH)));
        $safe = substr((string) preg_replace('/[^a-zA-Z0-9_\-.]/', '', $name), 0, 255);

        return ChunkValidator::validateFilename($safe) ? $safe : 'downloaded_file';
    }
}
