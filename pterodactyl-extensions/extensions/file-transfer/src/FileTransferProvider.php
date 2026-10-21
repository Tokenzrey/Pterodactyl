<?php

declare(strict_types=1);

namespace FileTransfer;

use FileTransfer\Console\CleanupCommand;
use FileTransfer\Support\ChunkStore;
use FileTransfer\Support\FileTransferSettings;
use FileTransfer\Support\PanelWingsFileService;
use FileTransfer\Support\RemoteFetcher;
use FileTransfer\Support\WingsFileService;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Http\Client\Factory;
use Pterodactyl\Extensions\ExtensionProvider;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

class FileTransferProvider extends ExtensionProvider
{
    public function register(): void
    {
        $this->app->bind(FileTransferSettings::class, fn ($app): FileTransferSettings => FileTransferSettings::fromRegistry($app->make(ExtensionSettingsRegistry::class)));

        // Where unfinished uploads live on the Panel's disk. Not the shared "local" disk: this path is ours alone.
        $this->app->singleton(ChunkStore::class, fn (): ChunkStore => new ChunkStore(storage_path('app/extensions/file-transfer')));

        // The Panel's own HTTP factory, so tests that fake it also fake the downloads.
        $this->app->singleton(RemoteFetcher::class, fn ($app): RemoteFetcher => new RemoteFetcher($app->make(Factory::class)));

        $this->app->bind(WingsFileService::class, PanelWingsFileService::class);
    }

    public function boot(): void
    {
        // POST /api/client/servers/{server}/extensions/file-transfer/{chunk,chunk/merge,remote-fetch}
        $this->registerServerApiRoutes($this->extensionPath('routes', 'server.php'));

        $this->registerSettings(FileTransferSettings::define($this->settings()));

        // Chunked upload uses the Panel's own file.create; fetching from a URL is the one new right (FR-FT13).
        $this->registerPermissions('Transfer files to server.', ['remote-fetch' => 'Download a file from a URL to the server.']);

        $this->registerCommands([CleanupCommand::class]);
        $this->registerSchedule(fn (Schedule $schedule) => $schedule->command('file-transfer:cleanup')->everyThirtyMinutes()->withoutOverlapping());
    }
}
