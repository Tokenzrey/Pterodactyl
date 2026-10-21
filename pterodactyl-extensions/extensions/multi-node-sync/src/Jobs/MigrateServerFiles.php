<?php

declare(strict_types=1);

namespace MultiNodeSync\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Http\Kernel;
use Illuminate\Contracts\Queue\ShouldBeUnique;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Http\Request;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Support\Facades\Log;
use MultiNodeSync\Models\Migration;
use MultiNodeSync\Support\MigrationJobException;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;
use Throwable;

/**
 * Transfers a server to a different node using the Panel's built-in server transfer mechanism.
 *
 * The job sends an internal sub-request to the Panel's Admin API transfer endpoint
 * (POST /api/admin/servers/{id}/transfer), which handles archiving on the source node,
 * downloading on the target node, and updating the server's node_id. The job then polls
 * the server's status until the transfer completes.
 */
class MigrateServerFiles implements ShouldBeUnique, ShouldQueue
{
    use Dispatchable;
    use InteractsWithQueue;
    use Queueable;

    public int $tries = 2;

    public int $uniqueFor = 7200;

    /**
     * Polling runs for up to MAX_POLL_DURATION_SECONDS, longer than the default worker limit of 60 seconds. Without this
     * the worker kills the job in the middle of the wait and the migration is left "running".
     */
    public int $timeout = 3700;

    private const POLL_INTERVAL_SECONDS = 5;

    private const MAX_POLL_DURATION_SECONDS = 3600;

    public function __construct(
        public readonly int $migrationId,
        public readonly string $jobId,
    ) {}

    public static function dispatchSafely(int $migrationId, string $jobId): void
    {
        try {
            static::dispatch($migrationId, $jobId);
        } catch (Throwable $e) {
            Log::warning('multi-node-sync: migration job could not be dispatched', ['migration_id' => $migrationId, 'error' => $e::class]);
        }
    }

    /** @return list<int> */
    public function backoff(): array
    {
        return [30];
    }

    public function uniqueId(): string
    {
        return "mns-{$this->migrationId}";
    }

    public function handle(): void
    {
        $migration = Migration::query()->find($this->migrationId);
        if ($migration === null) {
            return;
        }

        $server = Server::query()->find($migration->source_server_id);
        if ($server === null) {
            throw MigrationJobException::sourceUnavailable();
        }

        $this->updateProgress($migration, 10, Migration::RUNNING);

        $this->initiateTransfer($server, $migration);

        $this->updateProgress($migration, 20);

        $this->waitForTransferCompletion($server, $migration);

        $migration->update(['status' => Migration::COMPLETED, 'progress' => 100]);

        Log::info('multi-node-sync: server transfer completed', [
            'migration_id' => $this->migrationId,
            'server_id' => $server->id,
            'target_node_id' => $migration->target_node_id,
        ]);
    }

    /**
     * Sends an internal sub-request to the Panel's built-in transfer endpoint.
     * The extension runs inside the Panel's Laravel app, so it can call the
     * Admin API directly without an HTTP connection or external API key.
     */
    private function initiateTransfer(Server $server, Migration $migration): void
    {
        // The Panel's transfer route only accepts a root administrator, so the transfer runs as one.
        $admin = User::query()->where('root_admin', true)->first();
        if ($admin === null) {
            throw MigrationJobException::noAdmin();
        }

        $kernel = app(Kernel::class);
        $request = Request::create(
            "/api/admin/servers/{$server->id}/transfer",
            'POST',
            [
                'node_id' => $migration->target_node_id,
                'allocation_id' => $migration->target_allocation_id,
            ],
            [],
            [],
            ['HTTP_ACCEPT' => 'application/json'],
        );
        $request->setUserResolver(fn () => $admin);

        try {
            $response = $kernel->handle($request);
        } catch (Throwable $e) {
            Log::error('multi-node-sync: transfer initiation failed', [
                'migration_id' => $this->migrationId,
                'error' => $e::class,
            ]);
            throw MigrationJobException::targetUnavailable();
        }

        if ($response->getStatusCode() >= 400) {
            Log::error('multi-node-sync: transfer API rejected', [
                'migration_id' => $this->migrationId,
                'status' => $response->getStatusCode(),
            ]);
            throw MigrationJobException::targetUnavailable();
        }
    }

    /**
     * Polls the server's status until the transfer completes or fails.
     * The Panel sets the server status to 'transferring' during transfer,
     * then back to null when complete (with node_id updated to the target).
     */
    private function waitForTransferCompletion(Server $server, Migration $migration): void
    {
        $elapsed = 0;
        $lastProgress = 20;

        while ($elapsed < self::MAX_POLL_DURATION_SECONDS) {
            $server->refresh();

            if ($server->node_id === $migration->target_node_id && $server->status === null) {
                $this->updateProgress($migration, 100);

                return;
            }

            if ($server->status === 'transfer_failed') {
                throw MigrationJobException::targetUnavailable();
            }

            $progress = $this->estimateProgress($elapsed);
            if ($progress > $lastProgress) {
                $this->updateProgress($migration, $progress);
                $lastProgress = $progress;
            }

            sleep(self::POLL_INTERVAL_SECONDS);
            $elapsed += self::POLL_INTERVAL_SECONDS;
        }

        throw MigrationJobException::targetUnavailable();
    }

    private function estimateProgress(int $elapsed): int
    {
        $ratio = min($elapsed / self::MAX_POLL_DURATION_SECONDS, 1.0);

        return (int) (20 + $ratio * 75);
    }

    private function updateProgress(Migration $migration, int $progress, ?string $status = null): void
    {
        $update = ['progress' => $progress];
        if ($status !== null) {
            $update['status'] = $status;
        }
        $migration->update($update);
    }

    public function failed(Throwable $exception): void
    {
        $errorCode = $exception instanceof MigrationJobException ? $exception->errorCode() : 'unexpected_error';

        $migration = Migration::query()->find($this->migrationId);
        if ($migration !== null && $migration->status !== Migration::COMPLETED) {
            $migration->update([
                'status' => Migration::FAILED,
                'last_error' => $errorCode,
            ]);
        }

        Log::error('multi-node-sync: migration failed', [
            'migration_id' => $this->migrationId,
            'error_code' => $errorCode,
            'error' => $exception::class,
        ]);
    }
}
