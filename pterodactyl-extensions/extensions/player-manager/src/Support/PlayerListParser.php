<?php

declare(strict_types=1);

namespace PlayerManager\Support;

/**
 * Turns what an RCON list command answered into the players shape. Two formats are known: the JSON a server plugin
 * answers with (every field optional), and vanilla's "There are N of a max of M players online: a, b", which has
 * names only. Anything else is not recognized and gives no players. The raw text never leaves this class.
 */
final class PlayerListParser
{
    private const MAX_PING = 1000;

    /** Above this the answer is treated as broken, so a bad response cannot make a huge padded list. */
    private const MAX_PLAYERS = 10000;

    private const UUID = '/^[0-9a-f]{8}(-?)[0-9a-f]{4}\1[0-9a-f]{4}\1[0-9a-f]{4}\1[0-9a-f]{12}$/i';

    /**
     * @return array{online_count: int, max_count: ?int, players: list<array{name: string, uuid: ?string, ping: ?int, is_op: ?bool}>, recognized: bool}
     */
    public static function parse(string $raw): array
    {
        $json = json_decode($raw, true);

        if (is_array($json) && is_int($json['online_count'] ?? null) && $json['online_count'] >= 0 && $json['online_count'] <= self::MAX_PLAYERS
            && (! isset($json['players']) || is_array($json['players']))) {
            return self::result($json['online_count'], $json['max_count'] ?? null, $json['players'] ?? [], true);
        }

        if (preg_match('/There are (\d+) of a max of (\d+) players online:?(.*)/s', $raw, $match) === 1) {
            $names = array_filter(array_map('trim', explode(',', $match[3])), static fn (string $name): bool => $name !== '');

            return self::result((int) $match[1], (int) $match[2], array_map(static fn (string $name): array => ['name' => $name], array_values($names)), true);
        }

        return self::result(0, null, [], false);
    }

    /**
     * @param  list<mixed>  $players
     * @return array{online_count: int, max_count: ?int, players: list<array{name: string, uuid: ?string, ping: ?int, is_op: ?bool}>, recognized: bool}
     */
    private static function result(int $online, mixed $max, array $players, bool $recognized): array
    {
        $entries = array_map(static fn (mixed $player): array => self::player(is_array($player) ? $player : []), array_slice($players, 0, $online));

        // The RCON count is the truth (EC-PM3): short lists are padded with empty entries, long ones were cut above.
        while (count($entries) < $online) {
            $entries[] = self::player([]);
        }

        return [
            'online_count' => $online,
            'max_count' => is_int($max) && $max >= 0 ? $max : null,
            'players' => $entries,
            'recognized' => $recognized,
        ];
    }

    /** @param  array<mixed>  $raw */
    private static function player(array $raw): array
    {
        $ping = $raw['ping'] ?? null;

        return [
            'name' => is_string($raw['name'] ?? null) ? $raw['name'] : '',
            'uuid' => self::uuid($raw['uuid'] ?? null),
            'ping' => is_int($ping) && $ping >= 0 && $ping <= self::MAX_PING ? $ping : null,
            'is_op' => is_bool($raw['is_op'] ?? null) ? $raw['is_op'] : null,
        ];
    }

    /** A UUID with or without hyphens (never a mix), written with hyphens in lower case. Anything else is null. */
    private static function uuid(mixed $value): ?string
    {
        if (! is_string($value) || preg_match(self::UUID, $value) !== 1) {
            return null;
        }

        $hex = strtolower(str_replace('-', '', $value));

        return substr($hex, 0, 8).'-'.substr($hex, 8, 4).'-'.substr($hex, 12, 4).'-'.substr($hex, 16, 4).'-'.substr($hex, 20, 12);
    }
}
