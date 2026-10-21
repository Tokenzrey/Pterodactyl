<?php

declare(strict_types=1);

namespace ModpackInstaller\Http\Controllers;

use Illuminate\Contracts\Cache\LockTimeoutException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use ModpackInstaller\Jobs\ProcessModpackInstallation;
use ModpackInstaller\Support\CurseForgeClient;
use ModpackInstaller\Support\ModpackSettings;
use ModpackInstaller\Support\ModpackSource;
use ModpackInstaller\Support\ModpackSourceException;
use ModpackInstaller\Support\PathValidator;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionJobProgress;

/**
 * Queues the installation of a server pack. The browser says which file by id and nothing else: where it is downloaded
 * from and whether it is a server pack come from the source's own answer, never from the request (FR-MI4 to FR-MI6).
 */
final class InstallController extends Controller
{
    public const TABLE = 'ext_modpack_installer_jobs';

    /** An install that has not finished by now is taken for lost, so that it cannot block the next one for ever. */
    public const STALE_SECONDS = 3600;

    public function __construct(private readonly ExtensionJobProgress $progress) {}

    public function install(Request $request, Server $server, ModpackSettings $settings, Factory $http): JsonResponse
    {
        abort_unless($request->user()->can('ext.modpack-installer.install', $server), 403);

        $input = $request->validate([
            'source' => ['required', 'string', 'in:curseforge,modrinth'],
            'project_id' => ['required', 'string', 'max:64'],
            'file_id' => ['required', 'string', 'max:64'],
            'target_directory' => ['nullable', 'string', 'max:255'],
        ]);

        $source = ModpackSource::from($input['source']);
        $projectId = $input['project_id'];
        $fileId = $input['file_id'];
        // No folder means the server's root.
        $target = $input['target_directory'] ?? '.';

        if (preg_match($source->idPattern(), $projectId) !== 1 || preg_match($source->idPattern(), $fileId) !== 1) {
            return response()->json(['error' => 'invalid_id'], 422);
        }
        if ($target !== '.' && ($error = PathValidator::validate($target)) !== null) {
            return response()->json(['error' => $error], 422);
        }
        if (! $source->hasServerPacks()) {
            return response()->json(['error' => 'not_server_pack'], 422);
        }
        if ($settings->curseforgeApiKey() === null) {
            return response()->json(['error' => 'curseforge_not_configured'], 503);
        }

        try {
            $file = (new CurseForgeClient($http, (string) $settings->curseforgeApiKey()))->file($projectId, $fileId);
        } catch (ModpackSourceException $exception) {
            return response()->json(['error' => $exception->errorCode()], 503);
        }

        if ($file === null) {
            return response()->json(['error' => 'file_not_found'], 404);
        }
        if (! $file->isServerPack) {
            return response()->json(['error' => 'not_server_pack'], 422);
        }
        if ($file->downloadUrl === null) {
            // The author keeps the file on CurseForge only: it cannot be fetched from here.
            return response()->json(['error' => 'download_not_allowed'], 422);
        }
        if ($file->sizeBytes !== null && $file->sizeBytes > $settings->maxDownloadMb() * 1048576) {
            return response()->json(['error' => 'download_too_large'], 422);
        }

        // Look and insert as one step: two requests at once must not both find the pack free.
        $lock = Cache::lock("modpack-installer:install:{$server->uuid}:{$projectId}:{$fileId}", 10);

        try {
            $lock->block(5);
        } catch (LockTimeoutException) {
            return response()->json(['error' => 'install_in_progress'], 409);
        }

        try {
            $busy = DB::table(self::TABLE)
                ->where('server_uuid', $server->uuid)
                ->where('project_id', $projectId)
                ->where('file_id', $fileId)
                ->whereIn('status', ['pending', 'running'])
                ->where('updated_at', '>=', now()->subSeconds(self::STALE_SECONDS))
                ->exists();

            if ($busy) {
                return response()->json(['error' => 'install_in_progress'], 409);
            }

            // The id the browser follows is the progress record's own, and only someone who may install can read it.
            $record = $this->progress->begin('modpack-installer', $request->user(), $server, 'ext.modpack-installer.install');

            DB::table(self::TABLE)->insert([
                'server_uuid' => $server->uuid,
                'source' => $source->value,
                'project_id' => $projectId,
                'file_id' => $fileId,
                'target_directory' => $target,
                'job_id' => $record->id,
                'status' => 'pending',
                'created_at' => now(),
                'updated_at' => now(),
            ]);
        } finally {
            $lock->release();
        }

        DB::afterCommit(function () use ($server, $source, $projectId, $fileId, $target, $record): void {
            if (! ProcessModpackInstallation::dispatchSafely($server->uuid, $source, $projectId, $fileId, $target, $record->id)) {
                // Nothing will ever run: say so now, rather than leave the browser and the next request waiting.
                ProcessModpackInstallation::abandon($record->id, 'download_failed');
            }
        });

        return response()->json(['job_id' => $record->id], 202);
    }
}
