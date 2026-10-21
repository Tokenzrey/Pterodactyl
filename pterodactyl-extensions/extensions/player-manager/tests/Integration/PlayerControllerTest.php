<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Cache;
use PlayerManager\Support\PlayerManagerSettings;
use PlayerManager\Support\RconClient;
use PlayerManager\Support\RconClientFactory;
use PlayerManager\Support\RconConnection;
use PlayerManager\Support\RconException;
use PlayerManager\Tests\ExtensionTestCase;
use PlayerManager\Tests\FakeRconConnection;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\Subuser;
use Pterodactyl\Models\User;

uses(ExtensionTestCase::class);

const PM_PASSWORD = 'rcon-pass-DO-NOT-LEAK-7f3a';

/** The players endpoint for a server (AC-PM1). */
function playersUrl(Server $server, string $tail = 'players'): string
{
    return "/api/client/servers/{$server->uuid}/extensions/player-manager/{$tail}";
}

/**
 * Points the container at a fake RCON server that answers with $response. Returns a counter of how many RCON
 * connections were opened and the last one, so a test can read what was written to it.
 */
function rconAnswers(string $response, string $password = PM_PASSWORD): object
{
    // $response and $password stay changeable inside a test: Laravel keeps a route's controller (and with it the
    // factory it was built with) between requests, so a test must not rebind the factory halfway through.
    $counter = new class ($response, $password) {
        public int $opened = 0;

        public ?FakeRconConnection $last = null;

        public function __construct(public string $response, public string $password) {}
    };

    $server = static function (string $bytes) use ($counter): string {
        $id = unpack('V', substr($bytes, 4, 4))[1];
        $type = unpack('V', substr($bytes, 8, 4))[1];
        $body = substr($bytes, 12, -2);

        if ($type === 3) {
            return RconClient::packet($body === $counter->password ? $id : -1, 2, '');
        }
        if ($type === 2) {
            return RconClient::packet($id, 0, $counter->response);
        }

        return RconClient::packet($id, 0, '');
    };

    app()->instance(RconClientFactory::class, new RconClientFactory(static function () use ($counter, $server): RconConnection {
        $counter->opened++;

        return $counter->last = new FakeRconConnection($server);
    }));

    return $counter;
}

/** Makes the container's RCON factory fail every connection with the given code. */
function rconFailsWith(string $reason): void
{
    app()->instance(RconClientFactory::class, new RconClientFactory(static function () use ($reason): RconConnection {
        throw new RconException($reason, 'scripted failure');
    }));
}

/** A server with RCON configured for the players endpoint. */
function configuredServer(object $case): Server
{
    [, $server] = $case->generateTestAccount();
    app()->make(PlayerManagerSettings::class)->forServer($server)->update([
        'rcon_host' => '203.0.113.10',
        'rcon_port' => 25575,
        'rcon_password' => PM_PASSWORD,
    ]);

    return $server;
}

/** A subuser of the server with exactly these permissions. @param list<string> $permissions */
function subuserOf(Server $server, array $permissions): User
{
    $user = User::factory()->create();
    Subuser::query()->create(['user_id' => $user->id, 'server_id' => $server->id, 'permissions' => $permissions]);

    return $user;
}

test('a user with read gets the players as JSON with the contract shape (AC-PM1, AC-PM2)', function (): void {
    rconAnswers('{"online_count":2,"max_count":20,"players":[{"name":"Steve","uuid":"069a79f4-44e9-4726-a5be-fca90e38aaf5","ping":45,"is_op":true},{"name":"Alex","uuid":null,"ping":78,"is_op":false}]}');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->getJson(playersUrl($server))
        ->assertOk()
        ->assertExactJson([
            'online_count' => 2,
            'max_count' => 20,
            'players' => [
                ['name' => 'Steve', 'uuid' => '069a79f4-44e9-4726-a5be-fca90e38aaf5', 'ping' => 45, 'is_op' => true],
                ['name' => 'Alex', 'uuid' => null, 'ping' => 78, 'is_op' => false],
            ],
        ]);
});

test('vanilla list text gives names with the other fields null (AC-PM3)', function (): void {
    rconAnswers('There are 2 of a max of 20 players online: Steve, Alex');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->getJson(playersUrl($server))
        ->assertOk()
        ->assertJsonPath('players.0', ['name' => 'Steve', 'uuid' => null, 'ping' => null, 'is_op' => null]);
});

test('a server that Wings reports as off answers empty and never calls RCON (AC-PM4, FR-PM5)', function (string $state): void {
    $counter = rconAnswers('There are 3 of a max of 20 players online: Steve, Alex, Notch');
    $server = configuredServer($this);
    $this->wings->result = $state;

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->getJson(playersUrl($server))
        ->assertOk()
        ->assertExactJson(['online_count' => 0, 'max_count' => null, 'players' => []]);

    expect($counter->opened)->toBe(0);
})->with(['offline', 'stopped']);

test('when Wings cannot be reached the state is unknown and RCON is still tried (EC-PM11)', function (): void {
    $counter = rconAnswers('There are 1 of a max of 20 players online: Steve');
    $server = configuredServer($this);
    $this->wings->result = new DaemonConnectionException(new RuntimeException('wings is down'));

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->getJson(playersUrl($server))
        ->assertOk()
        ->assertJsonPath('players.0.name', 'Steve');

    expect($counter->opened)->toBe(1);
});

test('without RCON configured the answer is 503 rcon_not_configured (AC-PM5, FR-PM3)', function (): void {
    rconAnswers('');
    [, $server] = $this->generateTestAccount();

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->getJson(playersUrl($server))
        ->assertStatus(503)
        ->assertExactJson(['error' => 'rcon_not_configured']);
});

test('an unreachable host is 503 rcon_connection_failed (AC-PM6)', function (): void {
    rconFailsWith(RconException::CONNECTION_FAILED);
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->getJson(playersUrl($server))
        ->assertStatus(503)
        ->assertExactJson(['error' => 'rcon_connection_failed']);
});

test('a wrong RCON password is 503 rcon_auth_failed (AC-PM7)', function (): void {
    rconAnswers('', 'some-other-password');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->getJson(playersUrl($server))
        ->assertStatus(503)
        ->assertExactJson(['error' => 'rcon_auth_failed']);
});

test('a response cut off mid-packet is 503 rcon_error (AC-PM20)', function (): void {
    app()->instance(RconClientFactory::class, new RconClientFactory(static fn (): RconConnection => new FakeRconConnection(
        static function (string $bytes): string {
            $id = unpack('V', substr($bytes, 4, 4))[1];
            $type = unpack('V', substr($bytes, 8, 4))[1];

            return $type === 3 ? RconClient::packet($id, 2, '') : substr(RconClient::packet($id, 0, 'cut off here'), 0, 7);
        },
    )));
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->getJson(playersUrl($server))
        ->assertStatus(503)
        ->assertExactJson(['error' => 'rcon_error']);
});

test('the RCON password never appears in any response (NFR-PM2)', function (): void {
    rconAnswers('', 'wrong-password');
    $server = configuredServer($this);

    $body = $this->actingAs(subuserOf($server, ['ext.player-manager.read']))->getJson(playersUrl($server))->getContent();

    expect($body)->not->toContain(PM_PASSWORD);
});

test('a subuser without read is refused (AC-PM8, T-PM5)', function (): void {
    rconAnswers('There are 0 of a max of 20 players online:');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, []))->getJson(playersUrl($server))->assertForbidden();
});

test('kick with a reason sends kick <name> <reason> and answers 200 (AC-PM9)', function (): void {
    $counter = rconAnswers('');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.kick']))
        ->postJson(playersUrl($server, 'players/Steve/kick'), ['reason' => 'griefing'])
        ->assertOk()
        ->assertExactJson(['kicked' => true]);

    expect($counter->last->written[1])->toContain('kick Steve griefing');
});

test('a user without the kick permission is refused (AC-PM10, T-PM4)', function (): void {
    rconAnswers('');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->postJson(playersUrl($server, 'players/Steve/kick'))
        ->assertForbidden();
});

test('a name with an injection character is 422 and nothing is sent (AC-PM11, T-PM1)', function (): void {
    $counter = rconAnswers('');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.kick']))
        ->postJson(playersUrl($server, 'players/Ste;ve/kick'))
        ->assertStatus(422);

    expect($counter->opened)->toBe(0);
});

test('a name that is too short is 422 (AC-PM12)', function (): void {
    rconAnswers('');
    $server = configuredServer($this);

    $this->actingAs(subuserOf($server, ['ext.player-manager.kick']))
        ->postJson(playersUrl($server, 'players/ab/kick'))
        ->assertStatus(422);
});

test('two polls at once make one RCON call inside the cache window (AC-PM13, FR-PM16)', function (): void {
    $counter = rconAnswers('There are 1 of a max of 20 players online: Steve');
    $server = configuredServer($this);
    $user = subuserOf($server, ['ext.player-manager.read']);

    $this->actingAs($user)->getJson(playersUrl($server))->assertOk();
    $this->actingAs($user)->getJson(playersUrl($server))->assertOk()->assertJsonPath('players.0.name', 'Steve');

    expect($counter->opened)->toBe(1);
});

test('the shared-answer lock is held while RCON is called and released afterwards (AC-PM13, FR-PM16)', function (): void {
    $server = configuredServer($this);
    $key = "player-manager:players:{$server->id}:lock";
    $heldDuringCall = null;

    // The fake connection tries to take the same lock the controller must be holding while it talks to RCON.
    $rcon = rconAnswers('There are 0 of a max of 20 players online:');
    app()->instance(RconClientFactory::class, new RconClientFactory(static function () use (&$heldDuringCall, $key, $rcon): RconConnection {
        $competing = Cache::lock($key, 5);
        $heldDuringCall = $competing->get() === false;
        $competing->release();

        return $rcon->last = new FakeRconConnection(static function (string $bytes): string {
            $id = unpack('V', substr($bytes, 4, 4))[1];
            $type = unpack('V', substr($bytes, 8, 4))[1];

            return $type === 3 ? RconClient::packet($id, 2, '') : RconClient::packet($id, 0, $type === 2 ? 'There are 0 of a max of 20 players online:' : '');
        });
    }));

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))->getJson(playersUrl($server))->assertOk();

    $free = Cache::lock($key, 5);
    expect($heldDuringCall)->toBeTrue()
        ->and($free->get())->toBeTrue();
    $free->release();
});

test('the refresh interval travels in a header so the JSON contract stays as specified (FR-PM13)', function (?int $stored, string $header): void {
    rconAnswers('There are 0 of a max of 20 players online:');
    $server = configuredServer($this);
    if ($stored !== null) {
        app(PlayerManagerSettings::class)->forServer($server)->update(['poll_interval' => $stored]);
    }

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->getJson(playersUrl($server))
        ->assertOk()
        ->assertHeader('X-Poll-Interval', $header);
})->with([
    'the default' => [null, '10000'],
    'a stored value' => [30000, '30000'],
]);

test('an interval below 5 seconds or above 60 is held inside that range (FR-PM13)', function (int $stored, string $header): void {
    rconAnswers('There are 0 of a max of 20 players online:');
    $server = configuredServer($this);
    // The form rules refuse these, but a value written some other way must still not make the page hammer RCON.
    app(PlayerManagerSettings::class)->forServer($server)->update(['poll_interval' => $stored]);

    $this->actingAs(subuserOf($server, ['ext.player-manager.read']))
        ->getJson(playersUrl($server))
        ->assertHeader('X-Poll-Interval', $header);
})->with([
    'too fast' => [100, '5000'],
    'too slow' => [999999, '60000'],
]);

test('the 31st players request in a minute is 429 (AC-PM14, FR-PM17)', function (): void {
    rconAnswers('There are 0 of a max of 20 players online:');
    $server = configuredServer($this);
    $user = subuserOf($server, ['ext.player-manager.read']);

    for ($i = 0; $i < 30; $i++) {
        $this->actingAs($user)->getJson(playersUrl($server))->assertOk();
    }

    $this->actingAs($user)->getJson(playersUrl($server))->assertStatus(429);
});
