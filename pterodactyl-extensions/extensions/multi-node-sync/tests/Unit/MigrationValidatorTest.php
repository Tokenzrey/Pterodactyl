<?php

declare(strict_types=1);

use MultiNodeSync\Support\MigrationValidator;
use MultiNodeSync\Tests\ExtensionTestCase;
use Pterodactyl\Models\Allocation;
use Pterodactyl\Models\Server;

uses(ExtensionTestCase::class);

it('returns null when everything is in order', function (): void {
    $server = $this->createServerModel(['status' => null]);
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);

    expect(MigrationValidator::validate($server->id, $targetNode->id, $allocation->id))->toBeNull();
});

it('returns server_not_found when the source server does not exist', function (): void {
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);

    expect(MigrationValidator::validate(999999, $targetNode->id, $allocation->id))->toBe('server_not_found');
});

it('returns node_not_found when the target node does not exist', function (): void {
    $server = $this->createServerModel(['status' => null]);

    expect(MigrationValidator::validate($server->id, 999999, 1))->toBe('node_not_found');
});

it('returns same_node when the server is already on the target node (EC-MN1)', function (): void {
    $server = $this->createServerModel(['status' => null]);
    $allocation = Allocation::factory()->create(['node_id' => $server->node_id]);

    expect(MigrationValidator::validate($server->id, $server->node_id, $allocation->id))->toBe('same_node');
});

it('returns server_running for a server that is not in its ready state (EC-MN2)', function (?string $status): void {
    $server = $this->createServerModel(['status' => $status]);
    $targetNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);

    expect(MigrationValidator::validate($server->id, $targetNode->id, $allocation->id))->toBe('server_running');
})->with([
    Server::STATUS_INSTALLING,
    Server::STATUS_SUSPENDED,
    Server::STATUS_RESTORING_BACKUP,
    Server::STATUS_INSTALL_FAILED,
    Server::STATUS_REINSTALL_FAILED,
]);

it('refuses a target node that is in maintenance', function (): void {
    $server = $this->createServerModel(['status' => null]);
    $targetNode = $this->nodeModel(['maintenance_mode' => true]);
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id]);

    expect(MigrationValidator::validate($server->id, $targetNode->id, $allocation->id))->toBe('node_maintenance');
});

it('returns allocation_not_found when the allocation does not exist', function (): void {
    $server = $this->createServerModel(['status' => null]);
    $targetNode = $this->nodeModel();

    expect(MigrationValidator::validate($server->id, $targetNode->id, 999999))->toBe('allocation_not_found');
});

it('returns allocation_node_mismatch when the allocation belongs to a different node', function (): void {
    $server = $this->createServerModel(['status' => null]);
    $targetNode = $this->nodeModel();
    $otherNode = $this->nodeModel();
    $allocation = Allocation::factory()->create(['node_id' => $otherNode->id]);

    expect(MigrationValidator::validate($server->id, $targetNode->id, $allocation->id))->toBe('allocation_node_mismatch');
});

it('returns allocation_in_use when the allocation is already assigned to a server', function (): void {
    $server = $this->createServerModel(['status' => null]);
    $targetNode = $this->nodeModel();
    $otherServer = $this->createServerModel(['status' => null]);
    $allocation = Allocation::factory()->create(['node_id' => $targetNode->id, 'server_id' => $otherServer->id]);

    expect(MigrationValidator::validate($server->id, $targetNode->id, $allocation->id))->toBe('allocation_in_use');
});

it('reports same_node before server_running, since moving a server onto its own node is never right', function (): void {
    $server = $this->createServerModel(['status' => Server::STATUS_SUSPENDED]);
    $allocation = Allocation::factory()->create(['node_id' => $server->node_id]);

    expect(MigrationValidator::validate($server->id, $server->node_id, $allocation->id))->toBe('same_node');
});
