<?php

declare(strict_types=1);

namespace PlayerManager;

use PlayerManager\Fields\RconFields;
use PlayerManager\Support\PlayerManagerSettings;
use PlayerManager\Support\RconClientFactory;
use Pterodactyl\Extensions\ExtensionProvider;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionRepository;

class PlayerManagerProvider extends ExtensionProvider
{
    public function register(): void
    {
        $this->app->bind(PlayerManagerSettings::class, fn ($app): PlayerManagerSettings => new PlayerManagerSettings($app->make(ExtensionRepository::class)->settings(PlayerManagerSettings::ID)));

        // Tests rebind this so that no socket is opened; production uses a real TCP socket.
        $this->app->singleton(RconClientFactory::class, fn (): RconClientFactory => new RconClientFactory());
    }

    public function boot(): void
    {
        // GET and POST under /api/client/servers/{server}/extensions/player-manager.
        $this->registerServerApiRoutes($this->extensionPath('routes', 'server.php'));

        // ext.player-manager.{read,kick,ban,op,deop}: each action is its own subuser permission (FR-PM10).
        $this->registerPermissions('Manage Minecraft players.', [
            'read' => 'See who is online.',
            'kick' => 'Kick players.',
            'ban' => 'Ban players.',
            'op' => 'Give players operator status.',
            'deop' => 'Take operator status from players.',
        ]);

        // The RCON host, port and password on the admin server form (root administrators only).
        $this->registerFields(Server::class, RconFields::class);
    }
}
