<?php

declare(strict_types=1);

use OauthLogin\Support\Usernames;
use Pterodactyl\Rules\Username;

// EC-O2: usernames are sanitised to the Panel's own rule, made unique with a random suffix,
// and given up on after 5 lookups.

$free = fn (string $candidate): bool => false;

test('a clean hint is used as it is', function () use ($free): void {
    expect(Usernames::generate('octocat', $free))->toBe('octocat');
});

test('case is folded and foreign characters are transliterated or replaced', function (string $hint, string $expected): void {
    expect(Usernames::generate($hint, fn (): bool => false))->toBe($expected);
})->with([
    'upper case' => ['OctoCat', 'octocat'],
    'diacritics' => ['Müller', 'muller'],
    'inner space' => ['spaced name', 'spaced_name'],
    'outer junk' => ['  --..octocat..--  ', 'octocat'],
    'at sign' => ['a@b', 'a_b'],
]);

test('overlong hints are cut to 24 characters', function (): void {
    expect(Usernames::generate(str_repeat('a', 100), fn (): bool => false))->toBe(str_repeat('a', 24));
});

test('hints too short or empty after cleaning get a suffix so the 3 character minimum holds', function (string $hint, string $prefix): void {
    $name = Usernames::generate($hint, fn (): bool => false);

    expect($name)->toMatch('/^'.$prefix.'-[0-9a-f]{4}$/');
})->with([
    'one char' => ['x', 'x'],
    'two chars' => ['ab', 'ab'],
    'nothing left' => ['!!!', 'user'],
    'empty' => ['', 'user'],
    'only separators' => ['---', 'user'],
]);

test('every result satisfies the Panel username rule, whatever the hint', function (string $hint): void {
    $name = Usernames::generate($hint, fn (): bool => false);

    expect($name)->not->toBeNull()
        ->and(preg_match(Username::VALIDATION_REGEX, $name))->toBe(1)
        ->and(strlen($name))->toBeLessThanOrEqual(32);
})->with([
    'path traversal' => ['../../etc/passwd'],
    'script tag' => ['<script>alert(1)</script>'],
    'nul byte' => ["a\0b"],
    'newline' => ["x\nroot"],
    'emoji' => ['😀😀😀'],
    'cjk' => ['日本語'],
    'sql' => ["admin' OR 1=1 --"],
    'unicode dashes' => ["a\u{2013}b\u{2014}c"],
    'invalid utf8' => ["\xC3\x28abc"],
    'dots' => ['a...b'],
]);

test('a taken name gets a random suffix and the lookup sees each lower-case candidate', function (): void {
    $seen = [];
    $name = Usernames::generate('OctoCat', function (string $candidate) use (&$seen): bool {
        $seen[] = $candidate;

        return count($seen) < 3;
    });

    expect($seen)->toHaveCount(3)
        ->and($seen[0])->toBe('octocat')
        ->and($seen[1])->toMatch('/^octocat-[0-9a-f]{4}$/')
        ->and($name)->toBe($seen[2])
        ->and($name)->toMatch('/^octocat-[0-9a-f]{4}$/');
});

test('EC-O2 it gives up after 5 lookups', function (): void {
    $calls = 0;
    $name = Usernames::generate('octocat', function () use (&$calls): bool {
        $calls++;

        return true;
    });

    expect($name)->toBeNull()->and($calls)->toBe(5);
});

test('a name that needs a suffix from the start still gets only 5 lookups', function (): void {
    $calls = 0;
    $name = Usernames::generate('x', function () use (&$calls): bool {
        $calls++;

        return true;
    });

    expect($name)->toBeNull()->and($calls)->toBe(5);
});
