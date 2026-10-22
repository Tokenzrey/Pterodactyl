<?php

declare(strict_types=1);

namespace SubdomainManager\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Pterodactyl\Models\Server;
use SubdomainManager\Models\Record;
use SubdomainManager\Support\RoutedNames;
use SubdomainManager\Support\SubdomainSettings;

/**
 * The address of one server as its owner sees it, for the server console. Answers only what the console needs: the
 * name players type, its status, whether games sync routes it, and whether the port must be typed too. No token,
 * no zone id, no record id (AC-S13).
 */
final class AddressController
{
    public function __construct(private readonly SubdomainSettings $settings) {}

    public function show(Server $server): JsonResponse
    {
        $record = Record::query()->where('server_uuid', $server->uuid)->first();
        $record = $record?->status === Record::DELETING ? null : $record;
        $mode = $this->settings->mode();

        return response()->json([
            'address' => $record?->fqdn(),
            'status' => $record?->status,
            'mode' => $mode,
            // Per-port without SRV: the name alone does not carry the port, so players type it too.
            'needs_port' => $mode === 'per_port' && ! $this->settings->srvEnabled(),
            'routing' => RoutedNames::status($server, $mode),
        ]);
    }
}
