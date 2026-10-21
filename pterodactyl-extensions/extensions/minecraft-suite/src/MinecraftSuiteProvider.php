<?php

declare(strict_types=1);

namespace MinecraftSuite;

use MinecraftSuite\Fields\RconFields;
use MinecraftSuite\Support\MinecraftSuiteSettings;
use MinecraftSuite\Support\RconClientFactory;
use Pterodactyl\Extensions\ExtensionProvider;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionRepository;

class MinecraftSuiteProvider extends ExtensionProvider
{
    public function register(): void
    {
        $this->app->bind(MinecraftSuiteSettings::class, fn ($app): MinecraftSuiteSettings => new MinecraftSuiteSettings($app->make(ExtensionRepository::class)->settings(MinecraftSuiteSettings::ID)));

        // Tests rebind this so that no socket is opened; production uses a real TCP socket.
        $this->app->singleton(RconClientFactory::class, fn (): RconClientFactory => new RconClientFactory());
    }

    public function boot(): void
    {
        // GET /api/client/servers/{server}/extensions/minecraft-suite/health.
        $this->registerServerApiRoutes($this->extensionPath('routes', 'server.php'));

        // ext.minecraft-suite.read: seeing a server's health is its own subuser permission (FR-MS6).
        $this->registerPermissions('View Minecraft server health.', ['read' => 'See TPS, MSPT and uptime.']);

        // The RCON host, port, password and TPS command on the admin server form (root administrators only).
        $this->registerFields(Server::class, RconFields::class);
    }
}
