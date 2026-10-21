<?php

declare(strict_types=1);

namespace MultiNodeSync\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use MultiNodeSync\Jobs\MigrateServerFiles;
use MultiNodeSync\Models\Migration;
use MultiNodeSync\Support\MigrationValidator;
use Pterodactyl\Models\Server;

class MigrationController extends Controller
{
    public function index(Request $request): JsonResponse
    {
        $migrations = Migration::query()->orderByDesc('created_at')->limit(100)->get();

        return response()->json([
            'migrations' => $migrations->map(fn (Migration $m) => $this->serialize($m))->all(),
        ]);
    }

    public function show(Request $request, int $id): JsonResponse
    {
        $migration = Migration::query()->find($id);
        if ($migration === null) {
            return response()->json(['error' => 'migration_not_found'], 404);
        }

        return response()->json($this->serialize($migration));
    }

    public function create(Request $request): JsonResponse
    {
        $input = $request->validate([
            'source_server_id' => ['required', 'integer'],
            'target_node_id' => ['required', 'integer'],
            'target_allocation_id' => ['required', 'integer'],
        ]);

        $error = MigrationValidator::validate(
            (int) $input['source_server_id'],
            (int) $input['target_node_id'],
            (int) $input['target_allocation_id'],
        );

        if ($error !== null) {
            return response()->json(['error' => $error], 422);
        }

        $server = Server::query()->find((int) $input['source_server_id']);

        $migration = Migration::query()->create([
            'source_server_id' => $server->id,
            'source_server_uuid' => $server->uuid,
            'target_node_id' => (int) $input['target_node_id'],
            'target_allocation_id' => (int) $input['target_allocation_id'],
            'status' => Migration::PENDING,
        ]);

        return response()->json([
            'migration_id' => $migration->id,
            'status' => $migration->status,
        ], 201);
    }

    public function confirm(Request $request, int $id): JsonResponse
    {
        $migration = Migration::query()->find($id);
        if ($migration === null) {
            return response()->json(['error' => 'migration_not_found'], 404);
        }

        if ($migration->status !== Migration::PENDING) {
            return response()->json(['error' => 'migration_in_progress'], 409);
        }

        $input = $request->validate([
            'server_name_confirmation' => ['required', 'string', 'max:255'],
        ]);

        $server = Server::query()->find($migration->source_server_id);
        if ($server === null) {
            return response()->json(['error' => 'server_not_found'], 422);
        }

        if (! hash_equals($server->name, $input['server_name_confirmation'])) {
            return response()->json(['error' => 'confirmation_mismatch'], 422);
        }

        $jobId = Str::uuid()->toString();
        $migration->update([
            'status' => Migration::RUNNING,
            'job_id' => $jobId,
        ]);

        DB::afterCommit(function () use ($migration, $jobId): void {
            MigrateServerFiles::dispatchSafely($migration->id, $jobId);
        });

        return response()->json([
            'migration_id' => $migration->id,
            'status' => Migration::RUNNING,
            'job_id' => $jobId,
        ], 202);
    }

    public function cancel(Request $request, int $id): JsonResponse
    {
        $migration = Migration::query()->find($id);
        if ($migration === null) {
            return response()->json(['error' => 'migration_not_found'], 404);
        }

        if ($migration->status === Migration::RUNNING) {
            return response()->json(['error' => 'migration_in_progress'], 409);
        }

        if ($migration->status !== Migration::PENDING) {
            return response()->json(['error' => 'migration_not_cancellable'], 409);
        }

        $migration->update(['status' => Migration::CANCELLED]);

        return response()->json([
            'migration_id' => $migration->id,
            'status' => Migration::CANCELLED,
        ]);
    }

    /** @return array<string, mixed> */
    private function serialize(Migration $migration): array
    {
        return [
            'id' => $migration->id,
            'source_server_id' => $migration->source_server_id,
            'source_server_uuid' => $migration->source_server_uuid,
            'target_node_id' => $migration->target_node_id,
            'target_allocation_id' => $migration->target_allocation_id,
            'status' => $migration->status,
            'progress' => $migration->progress,
            'job_id' => $migration->job_id,
            'last_error' => $migration->last_error,
            'created_at' => $migration->created_at?->toIso8601String(),
            'updated_at' => $migration->updated_at?->toIso8601String(),
        ];
    }
}
