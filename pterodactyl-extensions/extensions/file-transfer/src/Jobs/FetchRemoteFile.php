<?php

declare(strict_types=1);

namespace FileTransfer\Jobs;

use FileTransfer\Support\ChunkStore;
use FileTransfer\Support\FileTransferSettings;
use FileTransfer\Support\PathValidator;
use FileTransfer\Support\RemoteFetcher;
use FileTransfer\Support\TransferException;
use FileTransfer\Support\WingsFileService;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldBeUnique;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Support\Facades\Log;
use InvalidArgumentException;
use Pterodactyl\Services\Extensions\ExtensionJobProgress;
use Throwable;

/**
 * Downloads a URL and puts the file on a server: downloading is 0 to 80 %, uploading 80 to 99 %, then done (FR-FT12).
 * The URL is checked again here with DNS, and the download is pinned to the checked address (RemoteFetcher). A failure
 * is reported as one fixed code (FR-FT19) on the progress record the browser is watching; only a failure that may pass
 * (a timeout, a server error, Wings being busy) is retried. The temporary file is removed whatever happens (NFR-FT5),
 * and nothing logged contains the URL (NFR-FT8).
 */
class FetchRemoteFile implements ShouldBeUnique, ShouldQueue
{
    use Dispatchable;
    use InteractsWithQueue;
    use Queueable;

    private const EXTENSION = 'file-transfer';

    public int $tries = 3;

    public int $uniqueFor = 1800;

    public int $timeout = 3600;

    public function __construct(
        public readonly string $serverUuid,
        public readonly string $url,
        public readonly string $targetDirectory,
        public readonly string $filename,
        public readonly string $progressId,
    ) {}

    public static function dispatchSafely(string $serverUuid, string $url, string $targetDirectory, string $filename, string $progressId): void
    {
        try {
            static::dispatch($serverUuid, $url, $targetDirectory, $filename, $progressId);
        } catch (Throwable $exception) {
            Log::warning('file-transfer: the fetch job could not be queued', ['server' => $serverUuid, 'error' => $exception::class]);
        }
    }

    /** @return list<int> */
    public function backoff(): array
    {
        return [10, 30];
    }

    public function uniqueId(): string
    {
        return "ftr-{$this->serverUuid}-{$this->progressId}";
    }

    public function handle(ExtensionJobProgress $progress, FileTransferSettings $settings, ChunkStore $store, RemoteFetcher $fetcher, WingsFileService $wings): void
    {
        $file = $store->tmpDir($this->progressId).'/'.$this->filename;

        try {
            $this->report($progress, 0, 'Downloading from remote URL...');

            $lastPercent = -1;
            $maxBytes = $settings->maxRemoteMb() * 1048576;
            $fetcher->download($this->url, $file, $maxBytes, function (int $written, ?int $total) use ($progress, $maxBytes, &$lastPercent): void {
                // 0 to 79 while downloading; the total is the server's figure, or else the limit as the best guess.
                $percent = min(79, (int) floor($written / ($total ?? $maxBytes) * 80));
                if ($percent > $lastPercent) {
                    $lastPercent = $percent;
                    $this->report($progress, $percent, 'Downloading from remote URL...');
                }
            });

            $this->report($progress, 80, 'Uploading to server...');
            $wings->upload($this->serverUuid, $file, PathValidator::join($this->targetDirectory, $this->filename));

            $this->report($progress, 100, 'File transferred successfully.', 'completed');
        } catch (TransferException $exception) {
            if ($exception->retryable && $this->attempts() < $this->tries) {
                throw $exception;
            }

            $this->fail($progress, $exception->reason);
        } catch (Throwable $exception) {
            // Not a failure the code knows about: say "download failed", keep the class for the operator.
            Log::error('file-transfer: the fetch failed unexpectedly', ['server' => $this->serverUuid, 'error' => $exception::class]);
            $this->fail($progress, 'download_failed');
        } finally {
            $store->deleteTmp($this->progressId);
        }
    }

    /** The queue gave up on the job itself (it ran past its time limit, or a worker died), so the browser is told. */
    public function failed(Throwable $exception): void
    {
        Log::error('file-transfer: the fetch job gave up', ['server' => $this->serverUuid, 'error' => $exception::class]);

        $this->fail(app(ExtensionJobProgress::class), 'timeout');
    }

    private function fail(ExtensionJobProgress $progress, string $code): void
    {
        Log::warning('file-transfer: remote fetch failed', ['server' => $this->serverUuid, 'code' => $code]);

        // The message of a failed record is the code: the browser puts it into words.
        $this->report($progress, 0, $code, 'failed');
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
}
