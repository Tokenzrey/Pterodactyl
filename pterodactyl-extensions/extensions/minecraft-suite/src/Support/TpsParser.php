<?php

declare(strict_types=1);

namespace MinecraftSuite\Support;

/**
 * Reads the text a TPS command answers with. Two formats are known (spark's "TPS (1m/5m/15m): a/b/c. MSPT: d" and
 * Paper's "TPS from last 1m, 5m, 15m: a, b, c"), plus the five-value form some builds print. Anything else is not
 * recognized and gives null for every value; this class never throws, whatever it is given (NFR-MS8).
 *
 * The line has to start the way a server prints it: a chat message that only mentions TPS is not a TPS line (T-MS9).
 */
final class TpsParser
{
    private const NUMBER = '(-?\d+(?:\.\d+)?)';

    /**
     * @return array{tps: array{'1m': ?float, '5m': ?float, '15m': ?float}, mspt: ?float, recognized: bool}
     */
    public static function parse(string $raw): array
    {
        // Colour codes ("§6") and Paper's asterisk for "above 20" are noise around the numbers.
        $text = preg_replace(['/\xC2\xA7[0-9a-fk-orA-FK-OR]/', '/\x1b\[[0-9;]*m/', '/\*/'], '', $raw) ?? '';
        $n = self::NUMBER;
        $start = '/^[^\w<]*';

        if (preg_match("{$start}TPS \(1m\/5m\/15m\):\s*{$n}\/{$n}\/{$n}\.?\s*MSPT:\s*{$n}/m", $text, $m) === 1) {
            return self::result([$m[1], $m[2], $m[3]], $m[4]);
        }
        if (preg_match("{$start}TPS from last 1m,\s*5m,\s*15m:\s*{$n},\s*{$n},\s*{$n}/m", $text, $m) === 1) {
            return self::result([$m[1], $m[2], $m[3]], null);
        }
        if (preg_match("{$start}TPS from last 5s,\s*10s,\s*1m,\s*5m,\s*15m:\s*{$n},\s*{$n},\s*{$n},\s*{$n},\s*{$n}/m", $text, $m) === 1) {
            return self::result([$m[3], $m[4], $m[5]], null);
        }

        return ['tps' => ['1m' => null, '5m' => null, '15m' => null], 'mspt' => null, 'recognized' => false];
    }

    /**
     * @param  list<string>  $tps  the 1m, 5m and 15m values as text
     * @return array{tps: array{'1m': ?float, '5m': ?float, '15m': ?float}, mspt: ?float, recognized: bool}
     */
    private static function result(array $tps, ?string $mspt): array
    {
        return [
            'tps' => ['1m' => self::tps($tps[0]), '5m' => self::tps($tps[1]), '15m' => self::tps($tps[2])],
            'mspt' => $mspt === null ? null : self::mspt($mspt),
            'recognized' => true,
        ];
    }

    /** Two decimals, never above 20 (a server cannot tick faster), and null for a negative value (EC-MS3). */
    private static function tps(string $value): ?float
    {
        $number = (float) $value;

        return $number < 0 ? null : min(20.0, round($number, 2));
    }

    private static function mspt(string $value): ?float
    {
        $number = (float) $value;

        return $number < 0 ? null : round($number, 2);
    }
}
