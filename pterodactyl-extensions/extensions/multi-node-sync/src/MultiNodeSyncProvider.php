<?php

declare(strict_types=1);

namespace MultiNodeSync;

use Illuminate\Console\Scheduling\Schedule;
use MultiNodeSync\Console\CleanupCommand;
use MultiNodeSync\Support\MultiNodeSyncSettings;
use MultiNodeSync\Support\WingsFileService;
use MultiNodeSync\Support\PanelWingsFileService;
use Pterodactyl\Extensions\ExtensionProvider;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

class MultiNodeSyncProvider extends ExtensionProvider
{
    public function register(): void
    {
        $this->app->bind(MultiNodeSyncSettings::class, fn ($app): MultiNodeSyncSettings => MultiNodeSyncSettings::fromRegistry($app->make(ExtensionSettingsRegistry::class)));
        $this->app->bind(WingsFileService::class, PanelWingsFileService::class);
    }

    public function boot(): void
    {
        $this->registerAdminApiRoutes($this->extensionPath('routes', 'admin.php'));

        $this->registerSettings(MultiNodeSyncSettings::define($this->settings()));

        $this->registerPermissions('Migrate servers and manage S3 transfers.', [
            'migrate' => 'Migrate server files between nodes.',
            's3-presign' => 'Generate S3 presigned URLs.',
        ]);

        $this->registerCommands([CleanupCommand::class]);
        $this->registerSchedule(fn (Schedule $schedule) => $schedule->command('multi-node-sync:cleanup')->hourly()->withoutOverlapping());
    }
}
