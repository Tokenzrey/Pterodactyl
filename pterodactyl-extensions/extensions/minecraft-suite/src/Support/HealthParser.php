<?php

declare(strict_types=1);

namespace MinecraftSuite\Support;

/** Puts the parsed TPS and Wings' uptime into the health answer's contract shape (FR-MS2). */
final class HealthParser
{
    /**
     * @param  array{tps: array{'1m': ?float, '5m': ?float, '15m': ?float}, mspt: ?float, recognized: bool}  $tps
     * @param  ?int  $uptimeMs  what Wings reports, in milliseconds; null when Wings could not be asked
     * @return array{tps: array{'1m': ?float, '5m': ?float, '15m': ?float}, mspt: ?float, uptime_seconds: ?int, version: null}
     */
    public static function build(array $tps, ?int $uptimeMs): array
    {
        return [
            'tps' => $tps['tps'],
            'mspt' => $tps['mspt'],
            // Wings reports 0 for "not measured yet", which is not an uptime of zero.
            'uptime_seconds' => $uptimeMs !== null && $uptimeMs > 0 ? intdiv($uptimeMs, 1000) : null,
            // RCON has no reliable source for the version, so it is not guessed.
            'version' => null,
        ];
    }

    /** A server that is off: nothing to measure (FR-MS4). */
    public static function offline(): array
    {
        return ['tps' => ['1m' => null, '5m' => null, '15m' => null], 'mspt' => null, 'uptime_seconds' => null, 'version' => null];
    }
}
