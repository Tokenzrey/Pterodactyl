<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Bus;
use MultiNodeSync\Jobs\MigrateServerFiles;
use MultiNodeSync\Models\Migration;
use MultiNodeSync\Tests\ExtensionTestCase;
use Pterodactyl\Models\Allocation;
use Pterodactyl\Models\Node;
use Pterodactyl\Models\Server;

uses(ExtensionTestCase::class);

const MIGRATIONS_URL = '/api/admin/extensions/multi-node-sync/migrations';

function createMigrationUrl(): string
{
    return MIGRATIONS_URL;
}

function confirmMigrationUrl(int $id): string
{
    return MIGRATIONS_URL."/{$id}/confirm";
}

function showMigrationUrl(int $id): string
{
    return MIGRATIONS_URL."/{$id}";
}

function cancelMigrationUrl(int $id): string
{
    return MIGRATIONS_URL."/{$id}";
}

function validMigrationInput(Server $server, Node $targetNode, Allocation $allocation): array
{
    return [
        'source_server_id' => $server->id,
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
    ];
}

it('creates a migration and returns 201 for an admin', function (): void {
    Bus::fake(MigrateServerFiles::class);
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $response = $this->postJson(createMigrationUrl(), validMigrationInput($server, $targetNode, $allocation));

    $response->assertStatus(201);
    expect($response->json('status'))->toBe('pending')
        ->and($response->json('migration_id'))->toBeInt();

    expect(Migration::query()->count())->toBe(1);
});

it('ignores a keep_source sent by the client, since the Panel decides what happens to the source', function (): void {
    Bus::fake(MigrateServerFiles::class);
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $this->postJson(createMigrationUrl(), [
        'source_server_id' => $server->id,
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
        'keep_source' => false,
    ])->assertStatus(201);

    expect(Migration::query()->first()->getAttributes())->not->toHaveKey('keep_source');
});

it('rejects same node migration with 422', function (): void {
    $this->actingAsAdmin();

    $node = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $node->id]);
    $server = $this->createServerModel(['node_id' => $node->id, 'status' => null]);

    $response = $this->postJson(createMigrationUrl(), [
        'source_server_id' => $server->id,
        'target_node_id' => $node->id,
        'target_allocation_id' => $allocation->id,
    ]);

    $response->assertStatus(422);
    expect($response->json('error'))->toBe('same_node');
});

it('rejects migration when server is running', function (): void {
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => Server::STATUS_INSTALLING]);

    $response = $this->postJson(createMigrationUrl(), validMigrationInput($server, $targetNode, $allocation));

    $response->assertStatus(422);
    expect($response->json('error'))->toBe('server_running');
});

it('rejects migration when allocation does not belong to target node', function (): void {
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $otherNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $otherNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $response = $this->postJson(createMigrationUrl(), validMigrationInput($server, $targetNode, $allocation));

    $response->assertStatus(422);
    expect($response->json('error'))->toBe('allocation_node_mismatch');
});

it('rejects non-admin from creating migration', function (): void {
    $user = \Pterodactyl\Models\User::factory()->create(['root_admin' => false]);
    $this->actingAs($user);

    $this->postJson(createMigrationUrl(), [])->assertForbidden();
});

it('confirms a migration with exact server name and dispatches job', function (): void {
    Bus::fake(MigrateServerFiles::class);
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null, 'name' => 'my-server']);

    $migration = Migration::query()->create([
        'source_server_id' => $server->id,
        'source_server_uuid' => $server->uuid,
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
        'status' => Migration::PENDING,
    ]);

    $response = $this->postJson(confirmMigrationUrl($migration->id), [
        'server_name_confirmation' => 'my-server',
    ]);

    $response->assertStatus(202);
    expect($response->json('status'))->toBe('running')
        ->and($response->json('job_id'))->not->toBeEmpty();

    Bus::assertDispatched(MigrateServerFiles::class);
});

it('rejects confirmation with wrong server name', function (): void {
    Bus::fake(MigrateServerFiles::class);
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null, 'name' => 'my-server']);

    $migration = Migration::query()->create([
        'source_server_id' => $server->id,
        'source_server_uuid' => $server->uuid,
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
        'status' => Migration::PENDING,
    ]);

    $response = $this->postJson(confirmMigrationUrl($migration->id), [
        'server_name_confirmation' => 'wrong-name',
    ]);

    $response->assertStatus(422);
    expect($response->json('error'))->toBe('confirmation_mismatch');
    Bus::assertNotDispatched(MigrateServerFiles::class);
});

it('rejects confirming a running migration with 409', function (): void {
    Bus::fake(MigrateServerFiles::class);
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $migration = Migration::query()->create([
        'source_server_id' => $server->id,
        'source_server_uuid' => $server->uuid,
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
        'status' => Migration::RUNNING,
        'job_id' => 'existing-job',
    ]);

    $response = $this->postJson(confirmMigrationUrl($migration->id), [
        'server_name_confirmation' => $server->name,
    ]);

    $response->assertStatus(409);
    expect($response->json('error'))->toBe('migration_in_progress');
});

it('cancels a pending migration', function (): void {
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $migration = Migration::query()->create([
        'source_server_id' => $server->id,
        'source_server_uuid' => $server->uuid,
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
        'status' => Migration::PENDING,
    ]);

    $response = $this->deleteJson(cancelMigrationUrl($migration->id));

    $response->assertOk();
    expect($response->json('status'))->toBe('cancelled')
        ->and(Migration::query()->find($migration->id)->status)->toBe(Migration::CANCELLED);
});

it('rejects cancelling a running migration with 409', function (): void {
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $migration = Migration::query()->create([
        'source_server_id' => $server->id,
        'source_server_uuid' => $server->uuid,
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
        'status' => Migration::RUNNING,
        'job_id' => 'running-job',
    ]);

    $response = $this->deleteJson(cancelMigrationUrl($migration->id));

    $response->assertStatus(409);
    expect($response->json('error'))->toBe('migration_in_progress');
});

it('lists migrations for an admin', function (): void {
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    Migration::query()->create([
        'source_server_id' => $server->id,
        'source_server_uuid' => $server->uuid,
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
        'status' => Migration::PENDING,
    ]);

    $response = $this->getJson(MIGRATIONS_URL);

    $response->assertOk();
    expect($response->json('migrations'))->toHaveCount(1);
});

it('shows a single migration', function (): void {
    $this->actingAsAdmin();

    $sourceNode = $this->nodeModel();
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);
    $server = $this->createServerModel(['node_id' => $sourceNode->id, 'status' => null]);

    $migration = Migration::query()->create([
        'source_server_id' => $server->id,
        'source_server_uuid' => $server->uuid,
        'target_node_id' => $targetNode->id,
        'target_allocation_id' => $allocation->id,
        'status' => Migration::PENDING,
    ]);

    $response = $this->getJson(showMigrationUrl($migration->id));

    $response->assertOk();
    expect($response->json('id'))->toBe($migration->id)
        ->and($response->json('status'))->toBe('pending')
        ->and($response->json('target_allocation_id'))->toBe($allocation->id);
});

it('returns 404 for a non-existent migration', function (): void {
    $this->actingAsAdmin();

    $this->getJson(showMigrationUrl(99999))->assertNotFound();
    $this->deleteJson(cancelMigrationUrl(99999))->assertNotFound();
});
