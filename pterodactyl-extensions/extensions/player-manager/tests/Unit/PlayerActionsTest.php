<?php

declare(strict_types=1);

use PlayerManager\Support\PlayerActions;
use PlayerManager\Support\RconClient;
use PlayerManager\Support\RconConnection;
use PlayerManager\Tests\FakeRconConnection;

/** The command body that went out in the EXECCOMMAND packet (written[0] is AUTH, written[1] the command). */
function sentCommand(FakeRconConnection $fake): string
{
    return substr($fake->written[1], 12, -2);
}

/** Actions over a fresh fake server; returns the actions and the fake so a test can read what was sent. */
function actionsFor(): array
{
    $fake = FakeRconConnection::minecraft('secret');
    $rcon = new RconClient('203.0.113.10', 25575, 'secret', static fn (): RconConnection => $fake);

    return [new PlayerActions($rcon), $fake];
}

test('kick with a reason sends kick <name> <reason> (AC-PM9)', function (): void {
    [$actions, $fake] = actionsFor();

    $actions->kick('Steve', 'griefing');

    expect(sentCommand($fake))->toBe('kick Steve griefing');
});

test('kick without a reason sends kick <name>', function (): void {
    [$actions, $fake] = actionsFor();

    $actions->kick('Steve');

    expect(sentCommand($fake))->toBe('kick Steve');
});

test('ban with a reason sends ban <name> <reason>', function (): void {
    [$actions, $fake] = actionsFor();

    $actions->ban('Steve', 'hacking');

    expect(sentCommand($fake))->toBe('ban Steve hacking');
});

test('op and deop send op <name> and deop <name>', function (): void {
    [$actions, $fake] = actionsFor();
    $actions->op('Steve');
    $secondCommand = sentCommand($fake);

    [$actions, $fake] = actionsFor();
    $actions->deop('Steve');

    expect($secondCommand)->toBe('op Steve')
        ->and(sentCommand($fake))->toBe('deop Steve');
});

test('actions return nothing: the RCON response is never handed back (FR-PM9)', function (): void {
    [$actions] = actionsFor();

    expect($actions->op('Steve'))->toBeNull();
});

test('injection rejected: a name with a separator, a newline or a space never reaches RCON (T-PM1, NFR-PM5)', function (string $name): void {
    [$actions, $fake] = actionsFor();

    expect(fn () => $actions->kick($name))->toThrow(InvalidArgumentException::class)
        ->and($fake->written)->toHaveCount(0);
})->with([
    'semicolon' => ['Ste;ve'],
    'command chain' => ['Steve;stop'],
    'pipe' => ['Steve|x'],
    'newline' => ["Steve\n"],
    'null byte' => ["Ste\0ve"],
    'space' => ['Steve stop'],
    'too short' => ['ab'],
    'too long' => [str_repeat('a', 17)],
    'non-ASCII' => ['Ünal'],
    'empty' => [''],
]);

test('a name of 3 to 16 letters, digits or underscores is accepted (FR-PM7)', function (string $name): void {
    [$actions, $fake] = actionsFor();

    $actions->op($name);

    expect(sentCommand($fake))->toBe("op {$name}");
})->with(['abc', 'Steve_01', str_repeat('a', 16)]);

test('a reason keeps only printable ASCII: newlines and null bytes are removed (EC-PM10)', function (): void {
    [$actions, $fake] = actionsFor();

    $actions->kick('Steve', "griefing\nstop\0now Ü");

    expect(sentCommand($fake))->toBe('kick Steve griefingstopnow');
});

test('a reason is cut to 256 characters (FR-PM8)', function (): void {
    [$actions, $fake] = actionsFor();

    $actions->ban('Steve', str_repeat('x', 300));

    expect(sentCommand($fake))->toBe('ban Steve '.str_repeat('x', 256));
});
