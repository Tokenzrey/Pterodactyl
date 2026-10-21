<?php

declare(strict_types=1);

use PlayerManager\Support\RconClient;
use PlayerManager\Support\RconConnection;
use PlayerManager\Support\RconException;
use PlayerManager\Tests\FakeRconConnection;

/** The RconException that $call raises. Fails the test when nothing is raised. */
function rconFailureOf(Closure $call): RconException
{
    try {
        $call();
    } catch (RconException $exception) {
        return $exception;
    }

    throw new RuntimeException('expected an RconException, none was raised');
}

function rconTo(FakeRconConnection $connection, string $password = 'secret'): RconClient
{
    return new RconClient('203.0.113.10', 25575, $password, static fn (): RconConnection => $connection);
}

test('authenticates with the password and returns the response text', function (): void {
    $fake = FakeRconConnection::minecraft('secret', ['There are 1 of a max of 20 players online: Steve']);

    expect(rconTo($fake)->command('list'))->toBe('There are 1 of a max of 20 players online: Steve')
        ->and($fake->closed)->toBeTrue();
});

test('a wrong password is rcon_auth_failed (AC-PM7)', function (): void {
    $exception = rconFailureOf(fn () => rconTo(FakeRconConnection::minecraft('right'), 'wrong')->command('list'));

    expect($exception->reason)->toBe(RconException::AUTH_FAILED);
});

test('the password never appears in a failure message (NFR-PM2)', function (): void {
    $exception = rconFailureOf(fn () => rconTo(FakeRconConnection::minecraft('right'), 'hunter2-wrong')->command('list'));

    expect($exception->getMessage())->not->toContain('hunter2-wrong');
});

test('the command goes out as an EXECCOMMAND packet followed by an empty sentinel (wire format)', function (): void {
    $fake = FakeRconConnection::minecraft('secret');

    rconTo($fake)->command('list');

    // AUTH id 1 type 3; command id 2 type 2 body "list"; sentinel id 3 type 0. Length field = bytes after itself.
    expect($fake->written[0])->toBe("\x10\x00\x00\x00\x01\x00\x00\x00\x03\x00\x00\x00secret\x00\x00")
        ->and($fake->written[1])->toBe("\x0e\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00list\x00\x00")
        ->and($fake->written[2])->toBe("\x0a\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00");
});

test('a response split over several packets is joined in order', function (): void {
    $fake = FakeRconConnection::minecraft('secret', ['Steve, ', 'Alex, ', 'Notch']);

    expect(rconTo($fake)->command('list'))->toBe('Steve, Alex, Notch');
});

test('an empty response is an empty string', function (): void {
    expect(rconTo(FakeRconConnection::minecraft('secret', ['']))->command('list'))->toBe('');
});

test('a response cut off mid-packet is rcon_error and the socket is still closed (review focus 1)', function (): void {
    $fake = new FakeRconConnection(static function (string $bytes): string {
        $id = unpack('V', substr($bytes, 4, 4))[1];
        $type = unpack('V', substr($bytes, 8, 4))[1];

        // The command gets the first nine bytes of its packet, then the stream ends.
        return $type === 3 ? RconClient::packet($id, 2, '') : substr(RconClient::packet($id, 0, 'There are 2 of a max'), 0, 9);
    });

    $exception = rconFailureOf(fn () => rconTo($fake)->command('list'));

    expect($exception->reason)->toBe(RconException::ERROR)
        ->and($fake->closed)->toBeTrue();
});

test('a silent server times out as rcon_timeout and the socket is still closed (NFR-PM4)', function (): void {
    $fake = new FakeRconConnection(static fn (): string => '');
    $fake->timesOut = true;

    $exception = rconFailureOf(fn () => rconTo($fake)->command('list'));

    expect($exception->reason)->toBe(RconException::TIMEOUT)
        ->and($fake->closed)->toBeTrue();
});

test('a refused connection is rcon_connection_failed (AC-PM6)', function (): void {
    $client = new RconClient('203.0.113.10', 25575, 'secret', static function (): never {
        throw new RconException(RconException::CONNECTION_FAILED, 'connection refused');
    });

    expect(rconFailureOf(fn () => $client->command('list'))->reason)->toBe(RconException::CONNECTION_FAILED);
});

test('a server that answers in slow drips is cut off at the overall deadline, not read forever (T-PM14)', function (): void {
    // Every read is within its own timeout, but twenty parts at 20 ms each would take 400 ms: past a 100 ms deadline.
    $fake = FakeRconConnection::minecraft('secret', array_fill(0, 20, 'x'));
    $fake->delayMicros = 20_000;
    $client = new RconClient('203.0.113.10', 25575, 'secret', static fn (): RconConnection => $fake, 0.1);

    $started = microtime(true);
    $exception = rconFailureOf(fn () => $client->command('list'));

    expect($exception->reason)->toBe(RconException::TIMEOUT)
        ->and(microtime(true) - $started)->toBeLessThan(0.3)
        ->and($fake->closed)->toBeTrue();
});

test('the socket opens with the 5 second timeout and the configured host and port (NFR-PM4)', function (): void {
    $seen = [];
    $fake = FakeRconConnection::minecraft('secret');
    $client = new RconClient('mc.example.com', 25576, 'secret', static function (string $host, int $port, float $timeout) use (&$seen, $fake): RconConnection {
        $seen = [$host, $port, $timeout];

        return $fake;
    });

    $client->command('list');

    expect($seen)->toBe(['mc.example.com', 25576, 5.0]);
});

test('an unexpected response id is rcon_error', function (): void {
    $fake = new FakeRconConnection(static function (string $bytes): string {
        $type = unpack('V', substr($bytes, 8, 4))[1];

        return $type === 3 ? RconClient::packet(1, 2, '') : RconClient::packet(99, 0, 'stray');
    });

    expect(rconFailureOf(fn () => rconTo($fake)->command('list'))->reason)->toBe(RconException::ERROR);
});

test('a packet longer than one RCON body is refused before it is read', function (): void {
    $fake = new FakeRconConnection(static function (string $bytes): string {
        $type = unpack('V', substr($bytes, 8, 4))[1];

        // Length field 5000: bigger than the 4096 byte body a Source server may send in one packet.
        return $type === 3 ? RconClient::packet(1, 2, '') : "\x88\x13\x00\x00";
    });

    expect(rconFailureOf(fn () => rconTo($fake)->command('list'))->reason)->toBe(RconException::ERROR);
});

test('an empty password is rcon_not_configured (AC-PM5)', function (): void {
    $exception = rconFailureOf(fn () => new RconClient('203.0.113.10', 25575, '', static fn (): RconConnection => FakeRconConnection::minecraft('')));

    expect($exception->reason)->toBe(RconException::NOT_CONFIGURED);
});

test('a port outside 1 to 65535 is rcon_not_configured (EC-PM8)', function (int $port): void {
    $exception = rconFailureOf(fn () => new RconClient('203.0.113.10', $port, 'secret', static fn (): RconConnection => FakeRconConnection::minecraft('secret')));

    expect($exception->reason)->toBe(RconException::NOT_CONFIGURED);
})->with([0, -1, 65536, 70000]);

test('a host that is not an address or a plain host name is rejected (NFR-PM3)', function (string $host): void {
    $exception = rconFailureOf(fn () => new RconClient($host, 25575, 'secret', static fn (): RconConnection => FakeRconConnection::minecraft('secret')));

    expect($exception->reason)->toBe(RconException::NOT_CONFIGURED);
})->with([
    'a URL' => ['http://169.254.169.254/latest'],
    'a path' => ['mc.example.com/admin'],
    'empty' => [''],
    'a space' => ['mc example'],
    'too long' => [str_repeat('a', 250).'.example.com'],
]);

test('IPv4, IPv6 and host names are accepted as targets (NFR-PM3)', function (string $host): void {
    expect(new RconClient($host, 25575, 'secret', static fn (): RconConnection => FakeRconConnection::minecraft('secret')))
        ->toBeInstanceOf(RconClient::class);
})->with(['127.0.0.1', '203.0.113.10', '::1', 'localhost', 'mc.example.com']);
