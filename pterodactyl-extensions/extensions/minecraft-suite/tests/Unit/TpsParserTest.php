<?php

declare(strict_types=1);

use MinecraftSuite\Support\TpsParser;

const MS_NO_TPS = ['tps' => ['1m' => null, '5m' => null, '15m' => null], 'mspt' => null, 'recognized' => false];

test('spark output gives the three TPS values and MSPT (AC-MS2)', function (): void {
    expect(TpsParser::parse('TPS (1m/5m/15m): 19.98/19.99/20.00. MSPT: 1.2'))->toBe([
        'tps' => ['1m' => 19.98, '5m' => 19.99, '15m' => 20.0],
        'mspt' => 1.2,
        'recognized' => true,
    ]);
});

test('Paper output gives the three TPS values and no MSPT (AC-MS3)', function (): void {
    expect(TpsParser::parse('TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0'))->toBe([
        'tps' => ['1m' => 20.0, '5m' => 20.0, '15m' => 20.0],
        'mspt' => null,
        'recognized' => true,
    ]);
});

test('colour codes and Paper\'s asterisk for "above 20" do not stop a line from being read', function (): void {
    $parsed = TpsParser::parse("\u{00A7}6TPS from last 1m, 5m, 15m: \u{00A7}a*20.0, \u{00A7}a19.5, \u{00A7}c14.2");

    expect($parsed['tps'])->toBe(['1m' => 20.0, '5m' => 19.5, '15m' => 14.2])
        ->and($parsed['recognized'])->toBeTrue();
});

test('a five-value line (5s, 10s, 1m, 5m, 15m) is read from its last three values', function (): void {
    $parsed = TpsParser::parse('TPS from last 5s, 10s, 1m, 5m, 15m: 20.0, 20.0, 19.9, 19.8, 19.7');

    expect($parsed['tps'])->toBe(['1m' => 19.9, '5m' => 19.8, '15m' => 19.7]);
});

test('output nobody recognizes gives null for everything, and says so (AC-MS4, EC-MS10)', function (): void {
    expect(TpsParser::parse('Unknown command. Type "/help" for help.'))->toBe(MS_NO_TPS);
});

test('an empty answer gives null for everything (EC-MS2)', function (): void {
    expect(TpsParser::parse(''))->toBe(MS_NO_TPS);
});

test('a chat line that contains a complete TPS line is not read as server output (T-MS9)', function (string $line): void {
    // These match the TPS formats word for word; only where they sit on the line tells them from the server's own.
    expect(TpsParser::parse($line))->toBe(MS_NO_TPS);
})->with([
    'Paper format in chat' => ['<Steve> TPS from last 1m, 5m, 15m: 20.0, 20.0, 20.0'],
    'spark format in chat' => ['<Steve> TPS (1m/5m/15m): 20.00/20.00/20.00. MSPT: 1.2'],
    'after other words' => ['Steve said TPS from last 1m, 5m, 15m: 1, 1, 1'],
]);

test('a TPS above 20 is cut to 20 (AC-MS8, T-MS5)', function (): void {
    $parsed = TpsParser::parse('TPS from last 1m, 5m, 15m: 25.0, 22.5, 20.0');

    expect($parsed['tps'])->toBe(['1m' => 20.0, '5m' => 20.0, '15m' => 20.0]);
});

test('a negative TPS becomes null, the others stay (EC-MS3)', function (): void {
    $parsed = TpsParser::parse('TPS from last 1m, 5m, 15m: -1.0, 20.0, 19.0');

    expect($parsed['tps'])->toBe(['1m' => null, '5m' => 20.0, '15m' => 19.0])
        ->and($parsed['recognized'])->toBeTrue();
});

test('a negative MSPT becomes null (EC-MS4)', function (): void {
    expect(TpsParser::parse('TPS (1m/5m/15m): 20.00/20.00/20.00. MSPT: -2')['mspt'])->toBeNull();
});

test('a value that is not a number becomes null', function (): void {
    expect(TpsParser::parse('TPS from last 1m, 5m, 15m: 1.2.3, 20.0, 20.0')['tps']['1m'])->toBeNull();
});

test('values are rounded to two decimals', function (): void {
    expect(TpsParser::parse('TPS (1m/5m/15m): 19.987/19.994/20.001. MSPT: 1.236')['tps'])->toBe(['1m' => 19.99, '5m' => 19.99, '15m' => 20.0]);
});

test('garbage and very long input never throw (NFR-MS8)', function (string $input): void {
    expect(TpsParser::parse($input))->toBe(MS_NO_TPS);
})->with([
    'binary' => [random_bytes(512)],
    'long' => [str_repeat('TPS ', 30000)],
    'only numbers' => ['20.0 20.0 20.0'],
]);
