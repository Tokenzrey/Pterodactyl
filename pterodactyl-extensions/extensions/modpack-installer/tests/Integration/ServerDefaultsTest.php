<?php

declare(strict_types=1);

use ModpackInstaller\Support\ModpackSettings;
use ModpackInstaller\Support\ServerDefaults;
use ModpackInstaller\Tests\ExtensionTestCase;
use ModpackInstaller\Tests\Fixtures;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

uses(ExtensionTestCase::class);

// Plan 12, "Pengaturan per-server": each server has its own search defaults, kept apart from the global settings.

function sdUrl(Server $server): string
{
    return Fixtures::url($server, 'defaults');
}

describe('who may read and change them', function (): void {
    it('refuses a guest', function (): void {
        [, $server] = $this->generateTestAccount();

        $this->getJson(sdUrl($server))->assertUnauthorized();
        $this->putJson(sdUrl($server), ['default_loader' => 'fabric'])->assertUnauthorized();
    });

    it('refuses a subuser without the install permission, and changes nothing', function (): void {
        [, $server] = $this->generateTestAccount();
        $user = Fixtures::subuser($server, ['file.read']);

        $this->actingAs($user)->getJson(sdUrl($server))->assertForbidden();
        $this->actingAs($user)->putJson(sdUrl($server), ['default_loader' => 'fabric'])->assertForbidden();

        expect(ServerDefaults::for($server)->get(ServerDefaults::LOADER))->toBe('');
    });

    it('refuses someone who is not on the server', function (): void {
        [, $server] = $this->generateTestAccount();

        $this->actingAs(User::factory()->create())->getJson(sdUrl($server))->assertStatus(404);
    });

    it('lets a subuser with the install permission read and change them', function (): void {
        [, $server] = $this->generateTestAccount();
        $user = Fixtures::subuser($server, [Fixtures::INSTALL]);

        $this->actingAs($user)->putJson(sdUrl($server), ['default_loader' => 'fabric'])->assertOk();
        $this->actingAs($user)->getJson(sdUrl($server))->assertOk()->assertJsonPath('default_loader', 'fabric');
    });
});

describe('what they hold', function (): void {
    it('starts from CurseForge, any version and any loader', function (): void {
        [$owner, $server] = $this->generateTestAccount();

        $this->actingAs($owner)->getJson(sdUrl($server))->assertOk()->assertExactJson([
            'default_source' => 'curseforge',
            'default_game_version' => '',
            'default_loader' => '',
        ]);
    });

    it('saves what was sent for this server, and only for this server', function (): void {
        [$owner, $server] = $this->generateTestAccount();
        [$otherOwner, $other] = $this->generateTestAccount();

        $this->actingAs($owner)->putJson(sdUrl($server), [
            'default_source' => 'curseforge',
            'default_game_version' => '1.20.1',
            'default_loader' => 'neoforge',
        ])->assertOk()->assertExactJson([
            'default_source' => 'curseforge',
            'default_game_version' => '1.20.1',
            'default_loader' => 'neoforge',
        ]);

        $this->actingAs($otherOwner)->getJson(sdUrl($other))->assertJsonPath('default_game_version', '');
        expect(ServerDefaults::for($server)->get(ServerDefaults::GAME_VERSION))->toBe('1.20.1');
    });

    it('changes only what was sent and keeps the rest', function (): void {
        [$owner, $server] = $this->generateTestAccount();
        $this->actingAs($owner)->putJson(sdUrl($server), ['default_game_version' => '1.20.1', 'default_loader' => 'fabric'])->assertOk();

        $this->actingAs($owner)->putJson(sdUrl($server), ['default_loader' => 'quilt'])->assertOk();

        $this->actingAs($owner)->getJson(sdUrl($server))->assertExactJson([
            'default_source' => 'curseforge',
            'default_game_version' => '1.20.1',
            'default_loader' => 'quilt',
        ]);
    });

    it('clears the loader and the version with an empty value', function (): void {
        [$owner, $server] = $this->generateTestAccount();
        $this->actingAs($owner)->putJson(sdUrl($server), ['default_game_version' => '1.20.1', 'default_loader' => 'fabric'])->assertOk();

        $this->actingAs($owner)->putJson(sdUrl($server), ['default_game_version' => '', 'default_loader' => ''])->assertOk()
            ->assertJsonPath('default_loader', '')
            ->assertJsonPath('default_game_version', '');
    });

    it('does not change the global settings, and the admin form never shows these keys', function (): void {
        [$owner, $server] = $this->generateTestAccount();
        $this->configureCurseForge(['max_download_mb' => 256]);

        $this->actingAs($owner)->putJson(sdUrl($server), ['default_loader' => 'fabric'])->assertOk();

        expect($this->settings()->maxDownloadMb())->toBe(256)
            ->and($this->settings()->curseforgeApiKey())->toBe(ExtensionTestCase::API_KEY);

        $keys = array_keys($this->app->make(ExtensionSettingsRegistry::class)->get(ModpackSettings::ID)->validationRules());
        expect($keys)->not->toContain('default_source', 'default_game_version', 'default_loader');
    });
});

it('refuses a source, a loader or a version it does not know, and saves nothing', function (array $body): void {
    [$owner, $server] = $this->generateTestAccount();

    $this->actingAs($owner)->putJson(sdUrl($server), $body)->assertStatus(422);

    expect(ServerDefaults::for($server)->get(ServerDefaults::SOURCE))->toBe('curseforge')
        ->and(ServerDefaults::for($server)->get(ServerDefaults::LOADER))->toBe('');
})->with([
    'unknown source' => [['default_source' => 'github']],
    'source by its label' => [['default_source' => 'CurseForge']],
    'unknown loader' => [['default_loader' => 'bukkit']],
    'loader with a space' => [['default_loader' => 'forge fabric']],
    'version with a parameter' => [['default_game_version' => '1.20&gameId=1']],
    'version too long' => [['default_game_version' => str_repeat('1', 21)]],
    'a valid loader and an invalid version together' => [['default_loader' => 'fabric', 'default_game_version' => '1 20']],
]);

it('stores a version without the spaces around it, since the framework trims input before the rules run', function (): void {
    [$owner, $server] = $this->generateTestAccount();

    $this->actingAs($owner)->putJson(sdUrl($server), ['default_game_version' => " 1.20.1\n"])->assertOk()->assertJsonPath('default_game_version', '1.20.1');

    expect(ServerDefaults::for($server)->get(ServerDefaults::GAME_VERSION))->toBe('1.20.1');
});
