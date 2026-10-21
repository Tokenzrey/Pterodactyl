<?php

declare(strict_types=1);

namespace ModpackInstaller;

use Illuminate\Console\Scheduling\Schedule;
use ModpackInstaller\Console\CleanupCommand;
use ModpackInstaller\Support\ModpackSettings;
use ModpackInstaller\Support\PanelWingsFileService;
use ModpackInstaller\Support\TmpStore;
use ModpackInstaller\Support\WingsFileService;
use Pterodactyl\Extensions\ExtensionProvider;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

class ModpackInstallerProvider extends ExtensionProvider
{
    public function register(): void
    {
        $this->app->bind(ModpackSettings::class, fn ($app): ModpackSettings => ModpackSettings::fromRegistry($app->make(ExtensionSettingsRegistry::class)));

        // Where an archive waits between the download and the upload. Not the shared "local" disk: this path is ours alone.
        $this->app->singleton(TmpStore::class, fn (): TmpStore => new TmpStore(storage_path('app/extensions/modpack-installer')));

        $this->app->bind(WingsFileService::class, PanelWingsFileService::class);
    }

    public function boot(): void
    {
        // GET .../search and POST .../install under /api/client/servers/{server}/extensions/modpack-installer
        $this->registerServerApiRoutes($this->extensionPath('routes', 'server.php'));

        $this->registerSettings(ModpackSettings::define($this->settings()));

        $this->registerPermissions('Install Minecraft modpacks.', [
            'install' => 'Search for and install a modpack on the server.',
        ]);

        $this->registerCommands([CleanupCommand::class]);
        $this->registerSchedule(fn (Schedule $schedule) => $schedule->command('modpack-installer:cleanup')->everyThirtyMinutes()->withoutOverlapping());
    }
}
