<?php

declare(strict_types=1);

use Illuminate\Contracts\Http\Kernel;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Illuminate\Support\Str;
use MultiNodeSync\Jobs\MigrateServerFiles;
use MultiNodeSync\Models\Migration;
use MultiNodeSync\Support\MigrationJobException;
use MultiNodeSync\Tests\ExtensionTestCase;
use Pterodactyl\Models\Allocation;
use Pterodactyl\Models\Node;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;

uses(ExtensionTestCase::class);

beforeEach(function (): void {
    // The Panel's transfer route only accepts a root administrator, and the job runs the transfer as one.
    User::factory()->create(['root_admin' => true]);
});

function createMigrationRecord(Server $server, Node $targetNode, Allocation $allocation): Migration
{
    return Migration::query()->create([
        'source_server_id' => $server->id,
        'source_server_uuid' => $server->uuid,
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
        'status' => Migration::RUNNING,
        'job_id' => Str::uuid()->toString(),
    ]);
}

/** Mocks the Panel's HTTP kernel so the transfer sub-request succeeds and moves the server to the target node. */
function fakeTransferKernel(Server $server, Node $targetNode, int $status = 204): void
{
    $kernel = Mockery::mock(Kernel::class);
    $kernel->shouldReceive('handle')->andReturnUsing(function (Request $request) use ($server, $targetNode, $status): Response {
        $server->update(['node_id' => $targetNode->id, 'status' => null]);

        return new Response(null, $status);
    });
    app()->instance(Kernel::class, $kernel);
}

/** Mocks the kernel to return an error response without moving the server. */
function failingTransferKernel(int $status = 500): void
{
    $kernel = Mockery::mock(Kernel::class);
    $kernel->shouldReceive('handle')->andReturn(new Response(null, $status));
    app()->instance(Kernel::class, $kernel);
}

function runJob(Migration $migration): void
{
    (new MigrateServerFiles($migration->id, $migration->job_id))->handle();
}

function failedWith(Migration $migration): ?string
{
    $job = new MigrateServerFiles($migration->id, $migration->job_id);

    try {
        $job->handle();
    } catch (Throwable $e) {
        $job->failed($e);
    }

    return $migration->refresh()->last_error;
}

it('completes the migration when the Panel transfer succeeds', function (): void {
    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    fakeTransferKernel($server, $targetNode);

    $migration = createMigrationRecord($server, $targetNode, $allocation);

    runJob($migration);

    $migration->refresh();
    expect($migration->status)->toBe(Migration::COMPLETED)
        ->and($migration->progress)->toBe(100);
});

it('updates the server node_id to the target node after transfer', function (): void {
    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    fakeTransferKernel($server, $targetNode);

    $migration = createMigrationRecord($server, $targetNode, $allocation);

    runJob($migration);

    expect($server->refresh()->node_id)->toBe($targetNode->id);
});

it('fails with target_unavailable when the transfer API rejects the request', function (): void {
    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    failingTransferKernel(422);

    $migration = createMigrationRecord($server, $targetNode, $allocation);

    expect(failedWith($migration))->toBe(MigrationJobException::TARGET_UNAVAILABLE);
});

it('fails with target_unavailable when the transfer API throws an exception', function (): void {
    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $kernel = Mockery::mock(Kernel::class);
    $kernel->shouldReceive('handle')->andThrow(new RuntimeException('transfer error'));
    app()->instance(Kernel::class, $kernel);

    $migration = createMigrationRecord($server, $targetNode, $allocation);

    expect(failedWith($migration))->toBe(MigrationJobException::TARGET_UNAVAILABLE);
});

it('fails with source_unavailable when the source server no longer exists', function (): void {
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);

    $migration = Migration::query()->create([
        'source_server_id' => 999999,
        'source_server_uuid' => Str::uuid()->toString(),
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
        'status' => Migration::RUNNING,
        'job_id' => Str::uuid()->toString(),
    ]);

    expect(failedWith($migration))->toBe(MigrationJobException::SOURCE_UNAVAILABLE);
});

it('fails with target_unavailable when the server enters transfer_failed status', function (): void {
    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $kernel = Mockery::mock(Kernel::class);
    $kernel->shouldReceive('handle')->andReturnUsing(function (Request $request) use ($server): Response {
        $server->update(['status' => 'transfer_failed']);

        return new Response(null, 204);
    });
    app()->instance(Kernel::class, $kernel);

    $migration = createMigrationRecord($server, $targetNode, $allocation);

    expect(failedWith($migration))->toBe(MigrationJobException::TARGET_UNAVAILABLE);
});

it('marks the migration failed with the error code when the job fails', function (): void {
    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    failingTransferKernel(500);

    $migration = createMigrationRecord($server, $targetNode, $allocation);

    $job = new MigrateServerFiles($migration->id, $migration->job_id);
    try {
        $job->handle();
    } catch (Throwable $e) {
        $job->failed($e);
    }

    $migration->refresh();
    expect($migration->status)->toBe(Migration::FAILED)
        ->and($migration->last_error)->toBe(MigrationJobException::TARGET_UNAVAILABLE);
});

it('does not mark a finished migration as failed', function (): void {
    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $migration = createMigrationRecord($server, $targetNode, $allocation);
    $migration->update(['status' => Migration::COMPLETED]);

    (new MigrateServerFiles($migration->id, $migration->job_id))->failed(new RuntimeException('late'));

    expect($migration->refresh()->status)->toBe(Migration::COMPLETED);
});

it('has ShouldBeUnique with unique id per migration', function (): void {
    $job1 = new MigrateServerFiles(1, 'job-1');
    $job2 = new MigrateServerFiles(1, 'job-2');
    $job3 = new MigrateServerFiles(2, 'job-3');

    expect($job1->uniqueId())->toBe('mns-1')
        ->and($job2->uniqueId())->toBe('mns-1')
        ->and($job3->uniqueId())->toBe('mns-2')
        ->and($job1->uniqueFor)->toBe(7200)
        ->and($job1->tries)->toBe(2);
});

it('returns 30 seconds backoff', function (): void {
    $job = new MigrateServerFiles(1, 'job-1');

    expect($job->backoff())->toBe([30]);
});

it('fails with no_admin when there is no root administrator to run the transfer as', function (): void {
    User::query()->update(['root_admin' => false]);

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $migration = createMigrationRecord($server, $targetNode, $allocation);

    expect(failedWith($migration))->toBe(MigrationJobException::NO_ADMIN);
});
