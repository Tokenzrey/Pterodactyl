<?php

declare(strict_types=1);

// Uses the helpers defined in HealthControllerTest.php (healthServer).

use Illuminate\Support\Facades\Validator;
use MinecraftSuite\Fields\RconFields;
use MinecraftSuite\Support\MinecraftSuiteSettings;
use MinecraftSuite\Tests\ExtensionTestCase;
use Pterodactyl\Models\ExtensionSetting;
use Pterodactyl\Services\Extensions\ExtensionPermissionRegistry;
use Pterodactyl\Services\Extensions\ExtensionSettingDefinition;

uses(ExtensionTestCase::class);

/** Saves the RCON fields the way the admin server form does: through the Panel's own admin endpoint. */
function saveHealthFields(object $case, Pterodactyl\Models\Server $server, array $values): Illuminate\Testing\TestResponse
{
    return $case->putJson(route('api.admin.servers.details', ['server' => $server->id]), [
        'name' => $server->name,
        'owner_id' => $server->owner_id,
        'extensions' => ['minecraft-suite' => $values],
    ]);
}

const MS_FORM = ['rcon_host' => '127.0.0.1', 'rcon_port' => 25575, 'rcon_password' => 'new-form-secret', 'tps_command' => 'tps', 'poll_interval' => 10000, 'cache_seconds' => 3];

test('an administrator saves the RCON fields through the real admin endpoint (FR-MS5)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->actingAs(Pterodactyl\Models\User::factory()->create(['root_admin' => true]));

    saveHealthFields($this, $server, MS_FORM)->assertOk();

    $stored = app(MinecraftSuiteSettings::class)->forServer($server);
    expect($stored->get('rcon_host'))->toBe('127.0.0.1')
        ->and($stored->get('rcon_port'))->toBe(25575)
        ->and($stored->get('rcon_password'))->toBe('new-form-secret')
        ->and($stored->get('tps_command'))->toBe('tps');
});

test('the admin response never carries the password, only the mask (NFR-MS2)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->actingAs(Pterodactyl\Models\User::factory()->create(['root_admin' => true]));

    $response = saveHealthFields($this, $server, MS_FORM)->assertOk();

    expect($response->getContent())->not->toContain('new-form-secret')
        ->and($response->getContent())->toContain(ExtensionSettingDefinition::MASK);
});

test('saving the form again with the mask keeps the stored password (NFR-MS2)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->actingAs(Pterodactyl\Models\User::factory()->create(['root_admin' => true]));
    saveHealthFields($this, $server, MS_FORM)->assertOk();

    saveHealthFields($this, $server, [...MS_FORM, 'rcon_host' => 'mc.example.com', 'rcon_password' => ExtensionSettingDefinition::MASK])->assertOk();

    $stored = app(MinecraftSuiteSettings::class)->forServer($server);
    expect($stored->get('rcon_host'))->toBe('mc.example.com')
        ->and($stored->get('rcon_password'))->toBe('new-form-secret');
});

test('a host that is a URL is refused with 422 and nothing is saved (NFR-MS3)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->actingAs(Pterodactyl\Models\User::factory()->create(['root_admin' => true]));

    saveHealthFields($this, $server, [...MS_FORM, 'rcon_host' => 'http://169.254.169.254/latest'])->assertStatus(422);

    expect(app(MinecraftSuiteSettings::class)->forServer($server)->get('rcon_host'))->toBe('');
});

test('a user who is not a root administrator cannot save them (NFR-MS3)', function (): void {
    [$owner, $server] = $this->generateTestAccount();
    $this->actingAs($owner);

    expect(saveHealthFields($this, $server, MS_FORM)->status())->toBeIn([401, 403, 404]);
    expect(app(MinecraftSuiteSettings::class)->forServer($server)->get('rcon_host'))->toBe('');
});

test('the single permission is registered as a subuser permission (FR-MS6)', function (): void {
    expect(array_keys(app(ExtensionPermissionRegistry::class)->all()['ext.minecraft-suite']['keys']))->toBe(['read']);
});

test('the RCON password is encrypted at rest and is not the stored text (NFR-MS2, T-MS1)', function (): void {
    healthServer($this);

    $row = ExtensionSetting::query()->where('extension', 'minecraft-suite')->where('key', 'rcon_password')->firstOrFail();

    expect($row->is_secret)->toBeTrue()
        ->and((string) $row->value)->not->toContain(MS_PASSWORD);
});

test('the admin form shows a mask where a password is stored and nothing where there is none (NFR-MS2)', function (): void {
    $server = healthServer($this);
    [, $bare] = $this->generateTestAccount();
    $settings = app(MinecraftSuiteSettings::class);

    expect(app(RconFields::class)->values($server, $settings)['rcon_password'])->toBe(ExtensionSettingDefinition::MASK)
        ->and(app(RconFields::class)->values($bare, $settings)['rcon_password'])->toBe('');
});

test('the form shows the defaults for the TPS command, interval and cache', function (): void {
    [, $bare] = $this->generateTestAccount();

    $values = app(RconFields::class)->values($bare, app(MinecraftSuiteSettings::class));

    expect($values['tps_command'])->toBe('spark tps')
        ->and($values['poll_interval'])->toBe(10000)
        ->and($values['cache_seconds'])->toBe(3);
});

test('saving the form with the mask keeps the stored password (NFR-MS2)', function (): void {
    $server = healthServer($this);
    $settings = app(MinecraftSuiteSettings::class);

    app(RconFields::class)->save($server, $settings, ['rcon_host' => '127.0.0.1', 'rcon_password' => ExtensionSettingDefinition::MASK]);

    expect($settings->forServer($server)->get('rcon_password'))->toBe(MS_PASSWORD)
        ->and($settings->forServer($server)->get('rcon_host'))->toBe('127.0.0.1');
});

test('a host that is a URL or has a path is refused by the form rules (NFR-MS3, T-MS2)', function (string $host): void {
    $rules = app(MinecraftSuiteSettings::class)->definition()->validationRules();

    expect(Validator::make(['rcon_host' => $host], ['rcon_host' => $rules['rcon_host']])->fails())->toBeTrue();
})->with(['http://169.254.169.254/latest', 'mc.example.com/admin', 'mc example']);

test('the form rules accept an address, a host name and the usual numbers', function (): void {
    $rules = app(MinecraftSuiteSettings::class)->definition()->validationRules();
    $input = ['rcon_host' => 'mc.example.com', 'rcon_port' => 25575, 'tps_command' => 'spark tps', 'poll_interval' => 10000, 'cache_seconds' => 3];

    expect(Validator::make($input, array_intersect_key($rules, $input))->passes())->toBeTrue();
});

test('the form rules refuse a poll interval below 5 seconds and a command with a line break (FR-MS9)', function (): void {
    $rules = app(MinecraftSuiteSettings::class)->definition()->validationRules();

    expect(Validator::make(['poll_interval' => 1000], ['poll_interval' => $rules['poll_interval']])->fails())->toBeTrue()
        ->and(Validator::make(['tps_command' => "tps\nstop"], ['tps_command' => $rules['tps_command']])->fails())->toBeTrue();
});
