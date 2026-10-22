<?php

declare(strict_types=1);

namespace SubdomainManager\Listeners;

use Illuminate\Validation\ValidationException;
use Pterodactyl\Events\Server\Updating;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use SubdomainManager\Models\Record;
use SubdomainManager\Support\Labels;
use SubdomainManager\Support\RoutedNames;
use SubdomainManager\Support\SubdomainSettings;

/**
 * Before a rename is saved (FR-R10): a name that gives no host name, or one another Minecraft server (or another
 * subdomain) already has, is refused here, with the reason. Throwing is what stops the save: the Panel's observer
 * does not look at a listener's return value.
 */
final class ServerRenaming
{
    public function __construct(private readonly ExtensionSettingsRegistry $registry) {}

    public function handle(Updating $event): void
    {
        $server = $event->server;
        if (! $server->isDirty('name') || ! RoutedNames::isMinecraft($server) || ! $this->routed()) {
            return;
        }

        $new = RoutedNames::label($server);
        if ($new === '') {
            throw ValidationException::withMessages(['name' => 'The name does not give a host name. Use letters or digits in the name.']);
        }

        // The same host name as before: nothing changes at Cloudflare, so nothing is refused (EC-R3).
        if ($new === Labels::slugFromName((string) $server->getOriginal('name'))) {
            return;
        }

        $other = RoutedNames::takenBy($server, $new);
        if ($other !== null) {
            throw ValidationException::withMessages(['name' => "The host name $new is already used by the server \"$other\"."]);
        }

        if (Record::query()->where('label', $new)->where('server_uuid', '!=', $server->uuid)->exists()) {
            throw ValidationException::withMessages(['name' => "The host name $new is already used by another subdomain."]);
        }
    }

    private function routed(): bool
    {
        return SubdomainSettings::fromRegistry($this->registry)->mode() === 'routed';
    }
}
