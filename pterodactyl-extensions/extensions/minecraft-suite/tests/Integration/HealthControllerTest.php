<?php

declare(strict_types=1);

use Illuminate\Log\Events\MessageLogged;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Event;
use MinecraftSuite\Support\MinecraftSuiteSettings;
use MinecraftSuite\Support\RconClient;
use MinecraftSuite\Support\RconClientFactory;
use MinecraftSuite\Support\RconConnection;
use MinecraftSuite\Support\RconException;
use MinecraftSuite\Tests\ExtensionTestCase;
use MinecraftSuite\Tests\FakeRconConnection;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\Subuser;
use Pterodactyl\Models\User;

uses(ExtensionTestCase::class);

const MS_PASSWORD = 'rcon-pass-DO-NOT-LEAK-9c1d';
const MS_SPARK = 'TPS (1m/5m/15m): 19.98/19.99/20.00. MSPT: 1.2';

function healthUrl(Server $server): string
{
    return "/api/client/servers/{$server->uuid}/extensions/minecraft-suite/health";
}

/**
 * Points the container at a fake RCON server. The answer and password stay changeable inside a test, because
 * Laravel keeps a route's controller (and its factory) between requests. Returns a counter and the last connection.
 */
function rconSays(string $response, string $password = MS_PASSWORD): object
{
    $counter = new class ($response, $password) {
        public int $opened = 0;

        public ?FakeRconConnection $last = null;

        public function __construct(public string $response, public string $password) {}
    };

    $server = static function (string $bytes) use ($counter): string {
        $id = unpack('V', substr($bytes, 4, 4))[1];
        $type = unpack('V', substr($bytes, 8, 4))[1];

        return match (true) {
            $type === 3 => RconClient::packet(substr($bytes, 12, -2) === $counter->password ? $id : -1, 2, ''),
            $type === 2 => RconClient::packet($id, 0, $counter->response),
            default => RconClient::packet($id, 0, ''),
        };
    };

    app()->instance(RconClientFactory::class, new RconClientFactory(static function () use ($counter, $server): RconConnection {
        $counter->opened++;

        return $counter->last = new FakeRconConnection($server);
    }));

    return $counter;
}

function rconBroken(string $reason): void
{
    app()->instance(RconClientFactory::class, new RconClientFactory(static function () use ($reason): RconConnection {
        throw new RconException($reason, 'scripted failure');
    }));
}

function healthServer(object $case): Server
{
    [, $server] = $case->generateTestAccount();
    app()->make(MinecraftSuiteSettings::class)->forServer($server)->update(['rcon_host' => '203.0.113.10', 'rcon_port' => 25575, 'rcon_password' => MS_PASSWORD]);

    return $server;
}

/** @param list<string> $permissions */
function healthUser(Server $server, array $permissions = ['ext.minecraft-suite.read']): User
{
    $user = User::factory()->create();
    Subuser::query()->create(['user_id' => $user->id, 'server_id' => $server->id, 'permissions' => $permissions]);

    return $user;
}

test('a user with read gets TPS, MSPT and uptime in the contract shape (AC-MS1)', function (): void {
    rconSays(MS_SPARK);
    $server = healthServer($this);
    $this->wings->uptime = 3_600_000;

    $this->actingAs(healthUser($server))
        ->getJson(healthUrl($server))
        ->assertOk()
        ->assertExactJson([
            'tps' => ['1m' => 19.98, '5m' => 19.99, '15m' => 20.0],
            'mspt' => 1.2,
            'uptime_seconds' => 3600,
            'version' => null,
        ]);
});

test('the default command is spark tps and a configured one replaces it (FR-MS3)', function (?string $configured, string $sent): void {
    $rcon = rconSays(MS_SPARK);
    $server = healthServer($this);
    if ($configured !== null) {
        app(MinecraftSuiteSettings::class)->forServer($server)->update(['tps_command' => $configured]);
    }

    $this->actingAs(healthUser($server))->getJson(healthUrl($server))->assertOk();

    // written[0] is AUTH, written[1] the command packet: its body starts after length, id and type.
    expect(substr($rcon->last->written[1], 12, -2))->toBe($sent);
})->with(['the default' => [null, 'spark tps'], 'a Paper server' => ['tps', 'tps']]);

test('output nobody recognizes still answers 200 with null for TPS and keeps the uptime (AC-MS4)', function (): void {
    rconSays('Unknown command. Type "/help" for help.');
    $server = healthServer($this);
    $this->wings->uptime = 120_000;

    $this->actingAs(healthUser($server))
        ->getJson(healthUrl($server))
        ->assertOk()
        ->assertExactJson(['tps' => ['1m' => null, '5m' => null, '15m' => null], 'mspt' => null, 'uptime_seconds' => 120, 'version' => null]);
});

test('a TPS above 20 is answered as 20 (AC-MS8)', function (): void {
    rconSays('TPS from last 1m, 5m, 15m: 25.0, 22.5, 20.0');
    $server = healthServer($this);

    // PHP writes 20.0 as 20 in JSON, so the decoded value is compared loosely (the number is the same to a browser).
    $tps = $this->actingAs(healthUser($server))->getJson(healthUrl($server))->assertOk()->json('tps');

    expect($tps)->toEqual(['1m' => 20, '5m' => 20, '15m' => 20]);
});

test('a server Wings reports as off answers all null and never calls RCON (AC-MS5, FR-MS4)', function (string $state): void {
    $counter = rconSays(MS_SPARK);
    $server = healthServer($this);
    $this->wings->result = $state;

    $this->actingAs(healthUser($server))
        ->getJson(healthUrl($server))
        ->assertOk()
        ->assertExactJson(['tps' => ['1m' => null, '5m' => null, '15m' => null], 'mspt' => null, 'uptime_seconds' => null, 'version' => null]);

    expect($counter->opened)->toBe(0);
})->with(['offline', 'stopped']);

test('when Wings cannot be reached RCON is still tried and uptime is null (EC-MS9)', function (): void {
    rconSays(MS_SPARK);
    $server = healthServer($this);
    $this->wings->result = new DaemonConnectionException(new RuntimeException('wings is down'));

    $this->actingAs(healthUser($server))
        ->getJson(healthUrl($server))
        ->assertOk()
        ->assertJsonPath('uptime_seconds', null)
        ->assertJsonPath('tps.1m', 19.98);
});

test('without RCON configured the answer is 503 rcon_not_configured (AC-MS6, FR-MS5)', function (): void {
    rconSays('');
    [, $server] = $this->generateTestAccount();

    $this->actingAs(healthUser($server))->getJson(healthUrl($server))->assertStatus(503)->assertExactJson(['error' => 'rcon_not_configured']);
});

test('every RCON failure is a 503 with only its fixed code (AC-MS18, FR-MS14)', function (string $reason): void {
    rconBroken($reason);
    $server = healthServer($this);

    $this->actingAs(healthUser($server))->getJson(healthUrl($server))->assertStatus(503)->assertExactJson(['error' => $reason]);
})->with([RconException::CONNECTION_FAILED, RconException::TIMEOUT, RconException::ERROR, RconException::AUTH_FAILED]);

test('a wrong RCON password is 503 rcon_auth_failed and the password is never in the body (NFR-MS2)', function (): void {
    rconSays('', 'some-other-password');
    $server = healthServer($this);

    $response = $this->actingAs(healthUser($server))->getJson(healthUrl($server));

    $response->assertStatus(503)->assertExactJson(['error' => 'rcon_auth_failed']);
    expect($response->getContent())->not->toContain(MS_PASSWORD);
});

test('a user without read is refused (AC-MS7, T-MS3)', function (): void {
    rconSays(MS_SPARK);
    $server = healthServer($this);

    $this->actingAs(healthUser($server, []))->getJson(healthUrl($server))->assertForbidden();
});

test('the server owner may read without being given the permission', function (): void {
    rconSays(MS_SPARK);
    [$owner, $server] = $this->generateTestAccount();
    app(MinecraftSuiteSettings::class)->forServer($server)->update(['rcon_host' => '127.0.0.1', 'rcon_port' => 25575, 'rcon_password' => MS_PASSWORD]);

    $this->actingAs($owner)->getJson(healthUrl($server))->assertOk();
});

test('a root administrator may read any server without being given the permission', function (): void {
    rconSays(MS_SPARK);
    $server = healthServer($this);

    $this->actingAs(User::factory()->create(['root_admin' => true]))->getJson(healthUrl($server))->assertOk();
});

test('two requests inside the cache window make one RCON call (AC-MS9, FR-MS13)', function (): void {
    $counter = rconSays(MS_SPARK);
    $server = healthServer($this);
    $user = healthUser($server);

    $this->actingAs($user)->getJson(healthUrl($server))->assertOk();
    $this->actingAs($user)->getJson(healthUrl($server))->assertOk();

    expect($counter->opened)->toBe(1);
});

test('the shared-answer lock is held while RCON is called and released afterwards (AC-MS9, FR-MS13)', function (): void {
    $server = healthServer($this);
    $key = "minecraft-suite:health:{$server->id}:lock";
    $heldDuringCall = null;

    // The fake connection tries to take the same lock the controller must be holding while it talks to RCON.
    app()->instance(RconClientFactory::class, new RconClientFactory(static function () use (&$heldDuringCall, $key): RconConnection {
        $competing = Cache::lock($key, 5);
        $heldDuringCall = $competing->get() === false;
        $competing->release();

        return new FakeRconConnection(static function (string $bytes): string {
            $id = unpack('V', substr($bytes, 4, 4))[1];
            $type = unpack('V', substr($bytes, 8, 4))[1];

            return $type === 3 ? RconClient::packet($id, 2, '') : RconClient::packet($id, 0, $type === 2 ? MS_SPARK : '');
        });
    }));

    $this->actingAs(healthUser($server))->getJson(healthUrl($server))->assertOk();

    $free = Cache::lock($key, 5);
    expect($heldDuringCall)->toBeTrue()
        ->and($free->get())->toBeTrue();
    $free->release();
});

test('with the cache off every request calls RCON (EC-MS12)', function (): void {
    $counter = rconSays(MS_SPARK);
    $server = healthServer($this);
    app(MinecraftSuiteSettings::class)->forServer($server)->update(['cache_seconds' => 0]);
    $user = healthUser($server);

    $this->actingAs($user)->getJson(healthUrl($server))->assertOk();
    $this->actingAs($user)->getJson(healthUrl($server))->assertOk();

    expect($counter->opened)->toBe(2);
});

test('a failure is not cached: the next request tries again (EC-MS9)', function (): void {
    $counter = rconSays(MS_SPARK, 'wrong-for-now');
    $server = healthServer($this);
    $user = healthUser($server);

    $this->actingAs($user)->getJson(healthUrl($server))->assertStatus(503);
    $counter->password = MS_PASSWORD;

    $this->actingAs($user)->getJson(healthUrl($server))->assertOk()->assertJsonPath('mspt', 1.2);
});

test('the 31st request in a minute is 429 (AC-MS10, T-MS4)', function (): void {
    rconSays(MS_SPARK);
    $server = healthServer($this);
    $user = healthUser($server);

    for ($i = 0; $i < 30; $i++) {
        $this->actingAs($user)->getJson(healthUrl($server))->assertOk();
    }

    $this->actingAs($user)->getJson(healthUrl($server))->assertStatus(429);
});

test('the refresh interval travels in a header, held to 5 to 60 seconds (FR-MS9)', function (?int $stored, string $header): void {
    rconSays(MS_SPARK);
    $server = healthServer($this);
    if ($stored !== null) {
        app(MinecraftSuiteSettings::class)->forServer($server)->update(['poll_interval' => $stored]);
    }

    $this->actingAs(healthUser($server))->getJson(healthUrl($server))->assertOk()->assertHeader('X-Poll-Interval', $header);
})->with(['default' => [null, '10000'], 'stored' => [30000, '30000'], 'too fast' => [100, '5000'], 'too slow' => [999999, '60000']]);

test('logs never hold the password or the raw RCON answer (NFR-MS7)', function (): void {
    $logged = [];
    Event::listen(MessageLogged::class, function (MessageLogged $event) use (&$logged): void {
        $logged[] = $event->message.' '.json_encode($event->context);
    });

    $rcon = rconSays('SECRET-SERVER-TEXT that is not a TPS line');
    $server = healthServer($this);
    $user = healthUser($server);
    $this->actingAs($user)->getJson(healthUrl($server))->assertOk();

    $rcon->password = 'a-different-password';
    cache()->flush();
    $this->actingAs($user)->getJson(healthUrl($server))->assertStatus(503);

    $text = implode("\n", $logged);

    // Without these the checks below would pass for the wrong reason: the listener has to have seen the entries.
    expect($text)->toContain('minecraft-suite: the TPS answer was not recognized')
        ->and($text)->toContain('minecraft-suite: RCON failed')
        ->and($text)->not->toContain(MS_PASSWORD)
        ->and($text)->not->toContain('SECRET-SERVER-TEXT');
});
