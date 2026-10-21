<?php

declare(strict_types=1);

// Uses the helpers defined in PlayerControllerTest.php (playersUrl, rconAnswers, configuredServer, subuserOf).

use Illuminate\Log\Events\MessageLogged;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Validator;
use PlayerManager\Fields\RconFields;
use PlayerManager\Support\PlayerManagerSettings;
use PlayerManager\Tests\ExtensionTestCase;
use Pterodactyl\Models\ExtensionSetting;
use Pterodactyl\Services\Extensions\ExtensionPermissionRegistry;
use Pterodactyl\Services\Extensions\ExtensionSettingDefinition;

uses(ExtensionTestCase::class);

/** Saves the RCON fields the way the admin server form does: through the Panel's own admin endpoint. */
function saveRconFields(object $case, Pterodactyl\Models\Server $server, array $values): Illuminate\Testing\TestResponse
{
    return $case->putJson(route('api.admin.servers.details', ['server' => $server->id]), [
        'name' => $server->name,
        'owner_id' => $server->owner_id,
        'extensions' => ['player-manager' => $values],
    ]);
}

const PM_FORM = ['rcon_host' => '127.0.0.1', 'rcon_port' => 25575, 'rcon_password' => 'new-form-secret', 'list_command' => 'list', 'poll_interval' => 10000, 'cache_seconds' => 3];

test('an administrator saves the RCON fields through the real admin endpoint (FR-PM3)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->actingAs(Pterodactyl\Models\User::factory()->create(['root_admin' => true]));

    saveRconFields($this, $server, PM_FORM)->assertOk();

    $stored = app(PlayerManagerSettings::class)->forServer($server);
    expect($stored->get('rcon_host'))->toBe('127.0.0.1')
        ->and($stored->get('rcon_port'))->toBe(25575)
        ->and($stored->get('rcon_password'))->toBe('new-form-secret')
        ->and($stored->get('list_command'))->toBe('list');
});

test('the admin response never carries the password, only the mask (NFR-PM2)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->actingAs(Pterodactyl\Models\User::factory()->create(['root_admin' => true]));

    $response = saveRconFields($this, $server, PM_FORM)->assertOk();

    expect($response->getContent())->not->toContain('new-form-secret')
        ->and($response->getContent())->toContain(ExtensionSettingDefinition::MASK);
});

test('saving the form again with the mask keeps the stored password (NFR-PM2)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->actingAs(Pterodactyl\Models\User::factory()->create(['root_admin' => true]));
    saveRconFields($this, $server, PM_FORM)->assertOk();

    saveRconFields($this, $server, [...PM_FORM, 'rcon_host' => 'mc.example.com', 'rcon_password' => ExtensionSettingDefinition::MASK])->assertOk();

    $stored = app(PlayerManagerSettings::class)->forServer($server);
    expect($stored->get('rcon_host'))->toBe('mc.example.com')
        ->and($stored->get('rcon_password'))->toBe('new-form-secret');
});

test('a host that is a URL is refused with 422 and nothing is saved (NFR-PM3)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->actingAs(Pterodactyl\Models\User::factory()->create(['root_admin' => true]));

    saveRconFields($this, $server, [...PM_FORM, 'rcon_host' => 'http://169.254.169.254/latest'])->assertStatus(422);

    expect(app(PlayerManagerSettings::class)->forServer($server)->get('rcon_host'))->toBe('');
});

test('a user who is not a root administrator cannot save them (NFR-PM3)', function (): void {
    [$owner, $server] = $this->generateTestAccount();
    $this->actingAs($owner);

    expect(saveRconFields($this, $server, PM_FORM)->status())->toBeIn([401, 403, 404]);
    expect(app(PlayerManagerSettings::class)->forServer($server)->get('rcon_host'))->toBe('');
});

test('the five permissions are registered as subuser permissions (FR-PM10)', function (): void {
    $group = app(ExtensionPermissionRegistry::class)->all()['ext.player-manager'];

    expect(array_keys($group['keys']))->toBe(['read', 'kick', 'ban', 'op', 'deop']);
});

test('the RCON password is encrypted at rest and is not the stored text (NFR-PM2, T-PM2)', function (): void {
    configuredServer($this);

    $row = ExtensionSetting::query()->where('extension', 'player-manager')->where('key', 'rcon_password')->firstOrFail();

    expect($row->is_secret)->toBeTrue()
        ->and((string) $row->value)->not->toContain(PM_PASSWORD);
});

test('the admin form shows a mask where a password is stored and nothing where there is none (NFR-PM2)', function (): void {
    $server = configuredServer($this);
    [, $bare] = $this->generateTestAccount();
    $fields = app(RconFields::class);

    expect($fields->values($server, app(PlayerManagerSettings::class))['rcon_password'])->toBe(ExtensionSettingDefinition::MASK)
        ->and($fields->values($bare, app(PlayerManagerSettings::class))['rcon_password'])->toBe('');
});

test('saving the form with the mask keeps the stored password (NFR-PM2)', function (): void {
    $server = configuredServer($this);
    $settings = app(PlayerManagerSettings::class);

    app(RconFields::class)->save($server, $settings, ['rcon_host' => '127.0.0.1', 'rcon_password' => ExtensionSettingDefinition::MASK]);

    expect($settings->forServer($server)->get('rcon_password'))->toBe(PM_PASSWORD)
        ->and($settings->forServer($server)->get('rcon_host'))->toBe('127.0.0.1');
});

test('a host that is a URL or has a path is refused by the form rules (NFR-PM3, T-PM3)', function (string $host): void {
    $rules = app(PlayerManagerSettings::class)->definition()->validationRules();

    expect(Validator::make(['rcon_host' => $host], ['rcon_host' => $rules['rcon_host']])->fails())->toBeTrue();
})->with(['http://169.254.169.254/latest', 'mc.example.com/admin', 'mc example']);

test('the form rules accept an address, a host name and the default numbers (NFR-PM3)', function (): void {
    $rules = app(PlayerManagerSettings::class)->definition()->validationRules();
    $input = ['rcon_host' => 'mc.example.com', 'rcon_port' => 25575, 'list_command' => 'list', 'poll_interval' => 10000, 'cache_seconds' => 3];

    expect(Validator::make($input, array_intersect_key($rules, $input))->passes())->toBeTrue();
});

test('a poll interval below 5 seconds is refused by the form rules (FR-PM13)', function (): void {
    $rules = app(PlayerManagerSettings::class)->definition()->validationRules();

    expect(Validator::make(['poll_interval' => 1000], ['poll_interval' => $rules['poll_interval']])->fails())->toBeTrue();
});

test('ban, op and deop send their commands and answer with their flag (FR-PM6, FR-PM9)', function (string $action, string $permission, string $command, array $answer): void {
    $counter = rconAnswers('');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ["ext.player-manager.{$permission}"]))
        ->postJson(playersUrl($server, "players/Steve/{$action}"), $action === 'ban' ? ['reason' => 'hacking'] : [])
        ->assertOk()
        ->assertExactJson($answer);

    expect($counter->last->written[1])->toContain($command);
})->with([
    'ban' => ['ban', 'ban', 'ban Steve hacking', ['banned' => true]],
    'op' => ['op', 'op', 'op Steve', ['op' => true]],
    'deop' => ['deop', 'deop', 'deop Steve', ['op' => false]],
]);

test('each action needs its own permission, not just another one (T-PM4)', function (string $action): void {
    rconAnswers('');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.read', 'ext.player-manager.kick']))
        ->postJson(playersUrl($server, "players/Steve/{$action}"))
        ->assertForbidden();
})->with(['ban', 'op', 'deop']);

test('the server owner may do everything without being given permissions (T-PM4)', function (): void {
    rconAnswers('There are 0 of a max of 20 players online:');
    [$owner, $server] = $this->generateTestAccount();
    app(PlayerManagerSettings::class)->forServer($server)->update(['rcon_host' => '127.0.0.1', 'rcon_port' => 25575, 'rcon_password' => PM_PASSWORD]);

    $this->actingAs($owner)->getJson(playersUrl($server))->assertOk();
    $this->actingAs($owner)->postJson(playersUrl($server, 'players/Steve/op'))->assertOk();
});

test('a root administrator may do everything on any server without being given permissions (T-PM4)', function (): void {
    rconAnswers('There are 0 of a max of 20 players online:');
    $server = configuredServer($this);
    $admin = Pterodactyl\Models\User::factory()->create(['root_admin' => true]);

    $this->actingAs($admin)->getJson(playersUrl($server))->assertOk();
    $this->actingAs($admin)->postJson(playersUrl($server, 'players/Steve/ban'))->assertOk();
});

test('a reason longer than 256 characters is refused with 422 (FR-PM8)', function (): void {
    $counter = rconAnswers('');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.kick']))
        ->postJson(playersUrl($server, 'players/Steve/kick'), ['reason' => str_repeat('x', 257)])
        ->assertStatus(422);

    expect($counter->opened)->toBe(0);
});

test('the 11th action in a minute is 429 (FR-PM17, T-PM10)', function (): void {
    rconAnswers('');
    $server = configuredServer($this);
    $user = subuserOf($server, ['ext.player-manager.op']);

    for ($i = 0; $i < 10; $i++) {
        $this->actingAs($user)->postJson(playersUrl($server, 'players/Steve/op'))->assertOk();
    }

    $this->actingAs($user)->postJson(playersUrl($server, 'players/Steve/op'))->assertStatus(429);
});

test('logs never hold the password, the raw RCON answer or a player UUID (NFR-PM8, T-PM2)', function (): void {
    $logged = [];
    Event::listen(MessageLogged::class, function (MessageLogged $event) use (&$logged): void {
        $logged[] = $event->message.' '.json_encode($event->context);
    });

    // A good answer with UUIDs, one the parser does not recognize, a failed login, and a moderation action.
    $rcon = rconAnswers('{"online_count":1,"players":[{"name":"Steve","uuid":"069a79f4-44e9-4726-a5be-fca90e38aaf5"}]}');
    $server = configuredServer($this);
    $user = subuserOf($server, ['ext.player-manager.read', 'ext.player-manager.kick']);
    $this->actingAs($user)->getJson(playersUrl($server))->assertOk();

    $rcon->response = 'SECRET-SERVER-TEXT that is not a player list';
    cache()->flush();
    $this->actingAs($user)->getJson(playersUrl($server))->assertOk();

    $rcon->password = 'a-different-password';
    $this->actingAs($user)->postJson(playersUrl($server, 'players/Steve/kick'))->assertStatus(503);

    $text = implode("\n", $logged);

    // Without these the checks below would pass for the wrong reason: the listener has to have seen the entries.
    expect($text)->toContain('player-manager: the player list answer was not recognized')
        ->and($text)->toContain('player-manager: RCON failed')
        ->and($text)->not->toContain(PM_PASSWORD)
        ->and($text)->not->toContain('SECRET-SERVER-TEXT')
        ->and($text)->not->toContain('069a79f4-44e9-4726-a5be-fca90e38aaf5');
});
