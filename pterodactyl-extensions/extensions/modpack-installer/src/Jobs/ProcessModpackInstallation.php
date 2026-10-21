<?php

declare(strict_types=1);

namespace ModpackInstaller\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldBeUnique;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Http\Client\Factory;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use InvalidArgumentException;
use ModpackInstaller\Http\Controllers\InstallController;
use ModpackInstaller\Support\CurseForgeClient;
use ModpackInstaller\Support\ModpackJobException;
use ModpackInstaller\Support\ModpackSettings;
use ModpackInstaller\Support\ModpackSource;
use ModpackInstaller\Support\ModpackSourceException;
use ModpackInstaller\Support\PackDownloader;
use ModpackInstaller\Support\PathValidator;
use ModpackInstaller\Support\ResolvedFile;
use ModpackInstaller\Support\Sanitizer;
use ModpackInstaller\Support\TmpStore;
use ModpackInstaller\Support\WingsException;
use ModpackInstaller\Support\WingsFileService;
use Pterodactyl\Services\Extensions\ExtensionJobProgress;
use Throwable;

/**
 * Installs a CurseForge server pack: asks the source for the file again, downloads it, hands it to the server, has Wings
 * extract it and removes the launch scripts that clash with the egg's own (FR-MI7). Progress goes to the record the
 * browser is watching: downloading 0 to 50, uploading 50 to 80, extracting 80 to 95, sanitizing 95 to 99 (FR-MI10).
 * A failure is one fixed code (FR-MI18) and only a failure that may not repeat is tried again.
 */
class ProcessModpackInstallation implements ShouldBeUnique, ShouldQueue
{
    use Dispatchable;
    use InteractsWithQueue;
    use Queueable;

    private const EXTENSION = 'modpack-installer';

    private const ARCHIVE = 'modpack.zip';

    public int $tries = 3;

    public int $uniqueFor = 3600;

    public int $timeout = 3600;

    public function __construct(
        public readonly string $serverUuid,
        public readonly ModpackSource $source,
        public readonly string $projectId,
        public readonly string $fileId,
        public readonly string $targetDirectory,
        public readonly string $progressId,
    ) {}

    /** Whether the job was queued. A queue that is down must not leave the browser waiting for a job that never runs. */
    public static function dispatchSafely(string $serverUuid, ModpackSource $source, string $projectId, string $fileId, string $targetDirectory, string $progressId): bool
    {
        try {
            static::dispatch($serverUuid, $source, $projectId, $fileId, $targetDirectory, $progressId);

            return true;
        } catch (Throwable $e) {
            Log::warning('modpack-installer: install job could not be dispatched', ['server' => $serverUuid, 'error' => $e::class]);

            return false;
        }
    }

    /** Ends an installation that will never run, on the record the browser watches and in the table. */
    public static function abandon(string $progressId, string $code): void
    {
        $progress = app(ExtensionJobProgress::class);
        $snapshot = $progress->find(self::EXTENSION, $progressId);

        // Whatever already finished stays as it ended.
        if ($snapshot !== null && $snapshot->status !== 'running') {
            return;
        }

        if ($snapshot !== null) {
            try {
                $progress->update(self::EXTENSION, $progressId, $snapshot->percent, $code, 'failed');
            } catch (InvalidArgumentException) {
                // Finished by someone else first.
            }
        }

        self::track($progressId, 'failed', $code);
    }

    /** @return list<int> */
    public function backoff(): array
    {
        return [10, 30, 60];
    }

    public function uniqueId(): string
    {
        return "mki-{$this->serverUuid}-{$this->projectId}-{$this->fileId}";
    }

    public function handle(ExtensionJobProgress $progress, ModpackSettings $settings, TmpStore $tmp, Factory $http, WingsFileService $wings): void
    {
        try {
            self::track($this->progressId, 'running');
            $this->report($progress, 0, 'Downloading server pack...');

            $file = $this->resolve($settings, $http);
            $archive = $tmp->dir($this->progressId).'/'.self::ARCHIVE;
            $this->download($progress, $http, $file, $archive, $settings->maxDownloadMb() * 1048576);

            $this->report($progress, 50, 'Uploading to server...');
            $this->upload($wings, $archive);

            $this->report($progress, 80, 'Extracting archive...');
            $this->extract($wings);

            $this->report($progress, 95, 'Removing conflicting files...');
            $this->sanitize($wings, Sanitizer::files($settings->extraSanitizedFiles()));

            $this->report($progress, 100, 'Modpack installed successfully.', 'completed');
            self::track($this->progressId, 'completed');
            Log::info('modpack-installer: installation completed', ['server' => $this->serverUuid, 'source' => $this->source->value, 'project' => $this->projectId]);
        } catch (ModpackJobException $exception) {
            if ($exception->retryable && $this->attempts() < $this->tries) {
                throw $exception;
            }

            $this->fail($progress, $exception->errorCode());
        } catch (Throwable $exception) {
            Log::error('modpack-installer: installation crashed', ['server' => $this->serverUuid, 'error' => $exception::class]);

            $this->fail($progress, $this->codeForStage($progress));
        } finally {
            $tmp->delete($this->progressId);
        }
    }

    /** The queue gave up on the job itself (it ran past its time limit, or a worker died), so the browser is told. */
    public function failed(Throwable $exception): void
    {
        Log::error('modpack-installer: the install job gave up', ['server' => $this->serverUuid, 'error' => $exception::class]);

        $this->fail(app(ExtensionJobProgress::class), $this->codeForStage(app(ExtensionJobProgress::class)));
    }

    /** Asks the source for the file again: what was checked when the request came in is not taken on trust. */
    private function resolve(ModpackSettings $settings, Factory $http): ResolvedFile
    {
        if (! $this->source->hasServerPacks()) {
            throw ModpackJobException::notServerPack();
        }

        $key = $settings->curseforgeApiKey();
        if ($key === null) {
            throw ModpackJobException::sourceUnavailable();
        }

        try {
            $file = (new CurseForgeClient($http, $key))->file($this->projectId, $this->fileId);
        } catch (ModpackSourceException) {
            throw ModpackJobException::sourceUnavailable();
        }

        if ($file === null) {
            throw ModpackJobException::fileNotFound();
        }
        if (! $file->isServerPack) {
            throw ModpackJobException::notServerPack();
        }
        if ($file->downloadUrl === null) {
            throw ModpackJobException::downloadFailed();
        }
        if ($file->sizeBytes !== null && $file->sizeBytes > $settings->maxDownloadMb() * 1048576) {
            throw ModpackJobException::downloadTooLarge();
        }

        return $file;
    }

    private function download(ExtensionJobProgress $progress, Factory $http, ResolvedFile $file, string $archive, int $maxBytes): void
    {
        $last = 0;

        (new PackDownloader($http))->download((string) $file->downloadUrl, $archive, $maxBytes, $file->sha1, function (int $written, ?int $total) use ($progress, $file, &$last): void {
            $size = $total ?? $file->sizeBytes;
            $percent = $size !== null && $size > 0 ? min(49, intdiv($written * 50, $size)) : 0;

            if ($percent > $last) {
                $last = $percent;
                $this->report($progress, $percent, 'Downloading server pack...');
            }
        });
    }

    private function upload(WingsFileService $wings, string $archive): void
    {
        try {
            $wings->upload($this->serverUuid, $archive, PathValidator::join($this->targetDirectory, self::ARCHIVE));
        } catch (WingsException $e) {
            Log::error('modpack-installer: upload failed', ['server' => $this->serverUuid, 'reason' => $e->getMessage()]);

            throw ModpackJobException::uploadFailed($e->unreachable);
        }
    }

    private function extract(WingsFileService $wings): void
    {
        $remote = PathValidator::join($this->targetDirectory, self::ARCHIVE);

        try {
            $wings->decompress($this->serverUuid, $remote);
        } catch (WingsException $e) {
            Log::error('modpack-installer: extraction failed', ['server' => $this->serverUuid, 'reason' => $e->getMessage()]);

            throw ModpackJobException::extractFailed();
        }

        // The archive has done its work; the pack is installed even if it cannot be removed.
        try {
            $wings->deleteFile($this->serverUuid, $remote);
        } catch (WingsException $e) {
            Log::warning('modpack-installer: could not delete the archive after extraction', ['server' => $this->serverUuid, 'reason' => $e->getMessage()]);
        }
    }

    /**
     * Removes the launch scripts from the root of the folder the pack was extracted into, and only those. One that is not
     * there is skipped (FR-MI9, EC-MI10).
     *
     * @param  list<string>  $names
     */
    private function sanitize(WingsFileService $wings, array $names): void
    {
        try {
            $present = $wings->listFiles($this->serverUuid, PathValidator::absolute($this->targetDirectory));

            foreach ($names as $name) {
                if (in_array($name, $present, true)) {
                    $wings->deleteFile($this->serverUuid, PathValidator::join($this->targetDirectory, $name));
                }
            }
        } catch (WingsException $e) {
            Log::error('modpack-installer: sanitizing failed', ['server' => $this->serverUuid, 'reason' => $e->getMessage()]);

            throw ModpackJobException::sanitizeFailed();
        }
    }

    /** For a failure nobody planned for: the code of the stage the record had reached. */
    private function codeForStage(ExtensionJobProgress $progress): string
    {
        $percent = $progress->find(self::EXTENSION, $this->progressId)?->percent ?? 0;

        return match (true) {
            $percent < 50 => ModpackJobException::DOWNLOAD_FAILED,
            $percent < 80 => ModpackJobException::UPLOAD_FAILED,
            $percent < 95 => ModpackJobException::EXTRACT_FAILED,
            default => ModpackJobException::SANITIZE_FAILED,
        };
    }

    private function fail(ExtensionJobProgress $progress, string $code): void
    {
        // A record that has already finished is not turned into a failure by a late call.
        $snapshot = $progress->find(self::EXTENSION, $this->progressId);
        if ($snapshot !== null && $snapshot->status !== 'running') {
            return;
        }

        Log::warning('modpack-installer: installation failed', ['server' => $this->serverUuid, 'source' => $this->source->value, 'project' => $this->projectId, 'code' => $code]);

        // The message of a failed record is the code: the browser puts it into words.
        $this->report($progress, 0, $code, 'failed');
        self::track($this->progressId, 'failed', $code);
    }

    /** Progress never goes backwards (a retry starts at 0 again), and a record that has expired or finished is left alone. */
    private function report(ExtensionJobProgress $progress, int $percent, string $message, string $status = 'running'): void
    {
        $snapshot = $progress->find(self::EXTENSION, $this->progressId);
        if ($snapshot === null || $snapshot->status !== 'running') {
            return;
        }

        try {
            $progress->update(self::EXTENSION, $this->progressId, max($percent, $snapshot->percent), $message, $status);
        } catch (InvalidArgumentException) {
            // Another worker finished it first.
        }
    }

    private static function track(string $progressId, string $status, ?string $error = null): void
    {
        DB::table(InstallController::TABLE)->where('job_id', $progressId)->update([
            'status' => $status,
            'last_error' => $error,
            'updated_at' => now(),
        ]);
    }
}
