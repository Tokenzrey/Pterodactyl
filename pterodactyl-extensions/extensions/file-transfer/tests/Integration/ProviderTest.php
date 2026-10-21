<?php

declare(strict_types=1);

use FileTransfer\Support\ChunkStore;
use FileTransfer\Support\FileTransferSettings;
use FileTransfer\Support\PanelWingsFileService;
use FileTransfer\Support\RemoteFetcher;
use FileTransfer\Support\WingsFileService;
use FileTransfer\Tests\ExtensionTestCase;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\Validator;
use Pterodactyl\Services\Extensions\ExtensionConsoleRegistry;
use Pterodactyl\Services\Extensions\ExtensionPermissionRegistry;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

uses(ExtensionTestCase::class);

test('it registers one permission, remote-fetch, with its own description (FR-FT13)', function (): void {
    $group = app(ExtensionPermissionRegistry::class)->all()['ext.file-transfer'];

    expect(array_keys($group['keys']))->toBe(['remote-fetch'])
        ->and($group['keys']['remote-fetch'])->not->toBe('');
});

test('its three routes are on the server API, each with the 30 per minute limit (FR-FT18)', function (): void {
    $routes = collect(Route::getRoutes()->getRoutes())->filter(fn ($route): bool => str_contains($route->uri(), 'extensions/file-transfer'));

    expect($routes->map(fn ($route): string => $route->methods()[0].' '.$route->uri())->sort()->values()->all())->toBe([
        'POST api/client/servers/{server}/extensions/file-transfer/chunk',
        'POST api/client/servers/{server}/extensions/file-transfer/chunk/merge',
        'POST api/client/servers/{server}/extensions/file-transfer/remote-fetch',
    ])->and($routes->every(fn ($route): bool => in_array('throttle:30,1,file-transfer', $route->gatherMiddleware(), true)))->toBeTrue();
});

test('the cleanup command is registered and runs every 30 minutes without overlapping (FR-FT17)', function (): void {
    // The Panel's kernel hands its scheduler to the registry; do the same with a fresh one.
    $schedule = new Schedule();
    app(ExtensionConsoleRegistry::class)->schedule($schedule);
    $events = collect($schedule->events())->filter(fn ($event): bool => str_contains((string) $event->command, 'file-transfer:cleanup'));

    expect(array_key_exists('file-transfer:cleanup', Artisan::all()))->toBeTrue()
        ->and($events)->toHaveCount(1)
        ->and($events->first()->expression)->toBe('*/30 * * * *')
        ->and($events->first()->withoutOverlapping)->toBeTrue();
});

describe('settings (FR-FT13)', function (): void {
    test('have the documented defaults', function (): void {
        $settings = app(FileTransferSettings::class);

        expect($settings->chunkSizeMb())->toBe(5)
            ->and($settings->maxFileMb())->toBe(2048)
            ->and($settings->maxRemoteMb())->toBe(1024)
            ->and($settings->cleanupChunkAgeHours())->toBe(2);
    });

    test('can be changed, and a value that is not a positive number falls back to the default', function (): void {
        $this->configure(['chunk_size_mb' => 8, 'max_file_mb' => 100]);
        $settings = app(FileTransferSettings::class);

        expect($settings->chunkSizeMb())->toBe(8)
            ->and($settings->maxFileMb())->toBe(100);

        $this->configure(['chunk_size_mb' => 0]);
        expect(app(FileTransferSettings::class)->chunkSizeMb())->toBe(5);
    });

    test('are validated to their ranges by the admin form rules', function (string $key, int $value, bool $valid): void {
        $rules = app(ExtensionSettingsRegistry::class)->get('file-transfer')->validationRules();

        expect(Validator::make([$key => $value], [$key => $rules[$key]])->passes())->toBe($valid);
    })->with([
        'chunk 1' => ['chunk_size_mb', 1, true], 'chunk 10' => ['chunk_size_mb', 10, true], 'chunk 0' => ['chunk_size_mb', 0, false], 'chunk 11' => ['chunk_size_mb', 11, false],
        'file 10240' => ['max_file_mb', 10240, true], 'file 10241' => ['max_file_mb', 10241, false],
        'remote 1' => ['max_remote_mb', 1, true], 'remote 0' => ['max_remote_mb', 0, false],
        'age 24' => ['cleanup_chunk_age_hours', 24, true], 'age 25' => ['cleanup_chunk_age_hours', 25, false],
    ]);

    test('send only the chunk size and the largest upload to the browser, never the server-side limits', function (): void {
        $public = app(ExtensionSettingsRegistry::class)->get('file-transfer')->frontendConfig(true);

        expect($public)->toHaveKeys(['chunk_size_mb', 'max_file_mb'])
            ->and($public)->not->toHaveKeys(['max_remote_mb', 'cleanup_chunk_age_hours']);
    });
});

describe('what the container hands out', function (): void {
    test('the real Wings service when nothing replaces it', function (): void {
        // The test base replaces the service with a fake; take that away to see what the provider bound.
        $this->app->forgetInstance(WingsFileService::class);

        expect($this->app->make(WingsFileService::class))->toBeInstanceOf(PanelWingsFileService::class);
    });

    test('a chunk store rooted in the Panel storage, and a fetcher over the Panel HTTP client', function (): void {
        $this->app->forgetInstance(ChunkStore::class);
        $this->app->forgetInstance(RemoteFetcher::class);

        $root = (new ReflectionProperty($this->app->make(ChunkStore::class), 'root'))->getValue($this->app->make(ChunkStore::class));

        expect($root)->toBe(storage_path('app/extensions/file-transfer'))
            ->and($this->app->make(RemoteFetcher::class))->toBeInstanceOf(RemoteFetcher::class);
    });
});
