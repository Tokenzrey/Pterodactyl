<?php

declare(strict_types=1);

use PlayerManager\Support\PlayerListParser;

test('a full JSON response is kept as it is (AC-PM2)', function (): void {
    $raw = '{"online_count":2,"max_count":20,"players":[{"name":"Steve","uuid":"069a79f4-44e9-4726-a5be-fca90e38aaf5","ping":45,"is_op":true},{"name":"Alex","uuid":"7228a3c2-2c1e-4e3b-8a3a-4c2b1e3a2c1e","ping":78,"is_op":false}]}';

    expect(PlayerListParser::parse($raw))->toBe([
        'online_count' => 2,
        'max_count' => 20,
        'players' => [
            ['name' => 'Steve', 'uuid' => '069a79f4-44e9-4726-a5be-fca90e38aaf5', 'ping' => 45, 'is_op' => true],
            ['name' => 'Alex', 'uuid' => '7228a3c2-2c1e-4e3b-8a3a-4c2b1e3a2c1e', 'ping' => 78, 'is_op' => false],
        ],
        'recognized' => true,
    ]);
});

test('JSON without the optional fields reads them as null (EC-PM2)', function (): void {
    $parsed = PlayerListParser::parse('{"online_count":1,"players":[{"name":"Steve"}]}');

    expect($parsed['max_count'])->toBeNull()
        ->and($parsed['players'])->toBe([['name' => 'Steve', 'uuid' => null, 'ping' => null, 'is_op' => null]]);
});

test('vanilla list text gives the names, with the other fields null (AC-PM3, review focus 2)', function (): void {
    expect(PlayerListParser::parse('There are 2 of a max of 20 players online: Steve, Alex'))->toBe([
        'online_count' => 2,
        'max_count' => 20,
        'players' => [
            ['name' => 'Steve', 'uuid' => null, 'ping' => null, 'is_op' => null],
            ['name' => 'Alex', 'uuid' => null, 'ping' => null, 'is_op' => null],
        ],
        'recognized' => true,
    ]);
});

test('vanilla list text with nobody online has no players', function (): void {
    expect(PlayerListParser::parse('There are 0 of a max of 20 players online: '))
        ->toMatchArray(['online_count' => 0, 'max_count' => 20, 'players' => [], 'recognized' => true]);
});

test('an empty response is not recognized and gives no players (EC-PM1)', function (): void {
    expect(PlayerListParser::parse(''))->toBe(['online_count' => 0, 'max_count' => null, 'players' => [], 'recognized' => false]);
});

test('text that is neither JSON nor a player list is not recognized (EC-PM1)', function (): void {
    expect(PlayerListParser::parse('Unknown command. Type "/help" for help.'))
        ->toMatchArray(['online_count' => 0, 'players' => [], 'recognized' => false]);
});

test('JSON of the wrong shape is not recognized', function (string $raw): void {
    expect(PlayerListParser::parse($raw))->toMatchArray(['online_count' => 0, 'players' => [], 'recognized' => false]);
})->with(['["Steve"]', '{"foo":1}', '{"online_count":"two","players":[]}', '{"online_count":-1,"players":[]}']);

test('a UUID that is not valid becomes null (EC-PM4, review focus 4)', function (): void {
    $parsed = PlayerListParser::parse('{"online_count":1,"players":[{"name":"Notch","uuid":"not-a-uuid"}]}');

    expect($parsed['players'][0]['uuid'])->toBeNull();
});

test('a UUID without hyphens is accepted and written with them, in lower case', function (): void {
    $parsed = PlayerListParser::parse('{"online_count":1,"players":[{"name":"Steve","uuid":"069A79F444E94726A5BEFCA90E38AAF5"}]}');

    expect($parsed['players'][0]['uuid'])->toBe('069a79f4-44e9-4726-a5be-fca90e38aaf5');
});

test('a ping that is negative or above 1000 becomes null (EC-PM5)', function (int $ping, ?int $expected): void {
    $parsed = PlayerListParser::parse(json_encode(['online_count' => 1, 'players' => [['name' => 'Steve', 'ping' => $ping]]], JSON_THROW_ON_ERROR));

    expect($parsed['players'][0]['ping'])->toBe($expected);
})->with([[-5, null], [1500, null], [0, 0], [45, 45], [1000, 1000]]);

test('is_op that is not a boolean becomes null (EC-PM6)', function (): void {
    $parsed = PlayerListParser::parse('{"online_count":2,"players":[{"name":"Steve","is_op":"yes"},{"name":"Alex","is_op":false}]}');

    expect($parsed['players'][0]['is_op'])->toBeNull()
        ->and($parsed['players'][1]['is_op'])->toBeFalse();
});

test('a negative max_count becomes null', function (): void {
    expect(PlayerListParser::parse('{"online_count":0,"max_count":-3,"players":[]}')['max_count'])->toBeNull();
});

test('fewer players than online_count are padded so the list matches the count (EC-PM3)', function (): void {
    $parsed = PlayerListParser::parse('{"online_count":3,"players":[{"name":"Steve"}]}');

    expect($parsed['online_count'])->toBe(3)
        ->and($parsed['players'])->toHaveCount(3)
        ->and($parsed['players'][2])->toBe(['name' => '', 'uuid' => null, 'ping' => null, 'is_op' => null]);
});

test('more players than online_count are cut to the count (EC-PM3)', function (): void {
    $parsed = PlayerListParser::parse('{"online_count":1,"players":[{"name":"Steve"},{"name":"Alex"}]}');

    expect($parsed['players'])->toHaveCount(1)
        ->and($parsed['players'][0]['name'])->toBe('Steve');
});

test('non-ASCII player names are kept (EC-PM7)', function (): void {
    $parsed = PlayerListParser::parse('{"online_count":1,"players":[{"name":"Ünal"}]}');

    expect($parsed['players'][0]['name'])->toBe('Ünal');
});
