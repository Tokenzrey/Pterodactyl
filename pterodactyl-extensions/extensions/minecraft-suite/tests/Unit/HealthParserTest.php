<?php

declare(strict_types=1);

use MinecraftSuite\Support\HealthParser;

const MS_TPS_OK = ['tps' => ['1m' => 19.98, '5m' => 19.99, '15m' => 20.0], 'mspt' => 1.2, 'recognized' => true];

test('the health answer has the contract shape (AC-MS1)', function (): void {
    expect(HealthParser::build(MS_TPS_OK, 3_600_000))->toBe([
        'tps' => ['1m' => 19.98, '5m' => 19.99, '15m' => 20.0],
        'mspt' => 1.2,
        'uptime_seconds' => 3600,
        'version' => null,
    ]);
});

test('uptime is taken from Wings in milliseconds and answered in whole seconds', function (?int $milliseconds, ?int $expected): void {
    expect(HealthParser::build(MS_TPS_OK, $milliseconds)['uptime_seconds'])->toBe($expected);
})->with([
    'a minute and a half' => [90_500, 90],
    'unknown' => [null, null],
    'nothing measured yet' => [0, null],
    'negative' => [-5, null],
]);

test('an answer that was not recognized still has uptime, and nothing made up for TPS (NFR-MS8)', function (): void {
    $health = HealthParser::build(['tps' => ['1m' => null, '5m' => null, '15m' => null], 'mspt' => null, 'recognized' => false], 120_000);

    expect($health['tps'])->toBe(['1m' => null, '5m' => null, '15m' => null])
        ->and($health['mspt'])->toBeNull()
        ->and($health['uptime_seconds'])->toBe(120);
});

test('an offline server answers null for everything (AC-MS5, FR-MS4)', function (): void {
    expect(HealthParser::offline())->toBe([
        'tps' => ['1m' => null, '5m' => null, '15m' => null],
        'mspt' => null,
        'uptime_seconds' => null,
        'version' => null,
    ]);
});

test('the version is always null: RCON has no reliable source for it (FR-MS2)', function (): void {
    expect(HealthParser::build(MS_TPS_OK, 1000)['version'])->toBeNull();
});
