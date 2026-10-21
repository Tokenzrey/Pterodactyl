<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

use Pterodactyl\Models\Allocation;
use Pterodactyl\Models\Node;
use Pterodactyl\Models\Server;

final class MigrationValidator
{
    /**
     * Whether a server may be transferred to a node, as an error code or null when it may.
     */
    public static function validate(int $sourceServerId, int $targetNodeId, int $targetAllocationId): ?string
    {
        $server = Server::query()->find($sourceServerId);
        if ($server === null) {
            return 'server_not_found';
        }

        $node = Node::query()->find($targetNodeId);
        if ($node === null) {
            return 'node_not_found';
        }

        if ($server->node_id === $node->id) {
            return 'same_node';
        }

        if ($server->status !== null) {
            return 'server_running';
        }

        if ($node->maintenance_mode) {
            return 'node_maintenance';
        }

        $allocation = Allocation::query()->find($targetAllocationId);
        if ($allocation === null) {
            return 'allocation_not_found';
        }

        if ($allocation->node_id !== $node->id) {
            return 'allocation_node_mismatch';
        }

        if ($allocation->server_id !== null) {
            return 'allocation_in_use';
        }

        return null;
    }
}
