<?php

declare(strict_types=1);

use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Route;
use ModpackInstaller\Support\PanelWingsFileService;
use ModpackInstaller\Support\TmpStore;
use ModpackInstaller\Support\WingsFileService;
use ModpackInstaller\Tests\ExtensionTestCase;
use Pterodactyl\Services\Extensions\ExtensionConsoleRegistry;
use Pterodactyl\Services\Extensions\ExtensionPermissionRegistry;

uses(ExtensionTestCase::class);

it('registers one permission, install, with its own description (FR-MI11)', function (): void {
    $group = app(ExtensionPermissionRegistry::class)->all()['ext.modpack-installer'];

    expect(array_keys($group['keys']))->toBe(['install'])
        ->and($group['keys']['install'])->not->toBe('');
});

it('puts its four routes on the server API, each with the 30 per minute limit (FR-MI17)', function (): void {
    $routes = collect(Route::getRoutes()->getRoutes())->filter(fn ($route): bool => str_contains($route->uri(), 'extensions/modpack-installer'));

    expect($routes->map(fn ($route): string => $route->methods()[0].' '.$route->uri())->sort()->values()->all())->toBe([
        'GET api/client/servers/{server}/extensions/modpack-installer/defaults',
        'GET api/client/servers/{server}/extensions/modpack-installer/search',
        'POST api/client/servers/{server}/extensions/modpack-installer/install',
        'PUT api/client/servers/{server}/extensions/modpack-installer/defaults',
    ])->and($routes->every(fn ($route): bool => in_array('throttle:30,1,modpack-installer', $route->gatherMiddleware(), true)))->toBeTrue();
});

it('registers the cleanup command, every 30 minutes and never twice at once (T-MI12)', function (): void {
    $schedule = new Schedule();
    app(ExtensionConsoleRegistry::class)->schedule($schedule);
    $events = collect($schedule->events())->filter(fn ($event): bool => str_contains((string) $event->command, 'modpack-installer:cleanup'));

    expect(array_key_exists('modpack-installer:cleanup', Artisan::all()))->toBeTrue()
        ->and($events)->toHaveCount(1)
        ->and($events->first()->expression)->toBe('*/30 * * * *')
        ->and($events->first()->withoutOverlapping)->toBeTrue();
});

it('hands out the real Wings service when nothing replaces it', function (): void {
    // The test base replaces the service with a fake; take that away to see what the provider bound.
    $this->app->forgetInstance(WingsFileService::class);

    expect($this->app->make(WingsFileService::class))->toBeInstanceOf(PanelWingsFileService::class);
});

it('keeps downloads in a store of its own under the Panel storage', function (): void {
    $this->app->forgetInstance(TmpStore::class);
    $store = $this->app->make(TmpStore::class);

    expect((new ReflectionProperty($store, 'root'))->getValue($store))->toBe(storage_path('app/extensions/modpack-installer'));
});
