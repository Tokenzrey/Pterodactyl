<?php

declare(strict_types=1);

use SubdomainManager\Support\Labels;

// FR-S2, AC-S9: the label rule is strict (lower case only) and the reserved list is compared
// without regard to case, because an administrator may type it however they like.

test('valid labels pass', function (string $label): void {
    expect(Labels::problem($label, []))->toBeNull();
})->with([
    'plain' => ['kampung'],
    'single letter' => ['a'],
    'digit first' => ['1a'],
    'digits only' => ['123'],
    'inner hyphen' => ['my-server'],
    'punycode' => ['xn--bcher-kva'],
    '63 characters' => [str_repeat('a', 63)],
]);

test('AC-S9 everything else is invalid', function (string $label): void {
    expect(Labels::problem($label, []))->toBe('invalid');
})->with([
    'empty' => [''],
    'upper case' => ['Kampung'],
    'all upper case' => ['KAMPUNG'],
    'underscore' => ['a_b'],
    'dot' => ['a.b'],
    'leading hyphen' => ['-a'],
    'trailing hyphen' => ['a-'],
    'only a hyphen' => ['-'],
    'space inside' => ['a b'],
    'leading space' => [' a'],
    'trailing space' => ['a '],
    'trailing newline' => ["a\n"],
    'nul byte' => ["a\0"],
    '64 characters' => [str_repeat('a', 64)],
    'accent' => ['ünï'],
    'cjk' => ['日本'],
    'double dot' => ['a..b'],
    'wildcard' => ['*'],
    'srv prefix' => ['_minecraft'],
    'path' => ['../x'],
]);

test('FR-S2 AC-S9 a reserved label is refused, whatever case the list was typed in', function (): void {
    expect(Labels::problem('www', ['www', 'mail']))->toBe('reserved')
        ->and(Labels::problem('mail', ['WWW', 'Mail']))->toBe('reserved')
        ->and(Labels::problem('kampung', ['www', 'mail']))->toBeNull();
});

test('a malformed label is invalid even when it is also on the reserved list', function (): void {
    expect(Labels::problem('WWW', ['www']))->toBe('invalid');
});

test('reserved entries that are not strings are ignored', function (): void {
    expect(Labels::problem('www', ['www', 5, null, ['x']]))->toBe('reserved')
        ->and(Labels::problem('kampung', [5, null]))->toBeNull();
});

test('fqdn joins a label and a domain in lower case', function (): void {
    expect(Labels::fqdn('kampung', 'mc.example.com'))->toBe('kampung.mc.example.com')
        ->and(Labels::fqdn('kampung', 'MC.Example.COM'))->toBe('kampung.mc.example.com');
});

test('the SRV name hangs the Minecraft service off the fqdn', function (): void {
    expect(Labels::srvName('kampung.mc.example.com'))->toBe('_minecraft._tcp.kampung.mc.example.com');
});

test('the built-in reserved list is itself made of acceptable entries', function (): void {
    expect(Labels::DEFAULT_RESERVED)->not->toBeEmpty();
    foreach (Labels::DEFAULT_RESERVED as $entry) {
        expect(Labels::isReservedEntry($entry))->toBeTrue("default entry $entry");
    }
    expect(Labels::DEFAULT_RESERVED)->toContain('www')->toContain('mail')->toContain('admin');
});

test('reserved entries are labels, or start with an underscore for service names', function (string $entry, bool $ok): void {
    expect(Labels::isReservedEntry($entry))->toBe($ok);
})->with([
    ['www', true],
    ['_dmarc', true],
    ['_domainkey', true],
    ['_', false],
    ['', false],
    ['a.b', false],
    ['WWW', false],
    ['-x', false],
    ['x y', false],
    [str_repeat('a', 64), false],
]);

// FR-R2, AC-R1, NFR-R3: the same rule as games.py slugify. The vectors are shared with src/client/labels.spec.ts.
test('slugFromName matches games.py slugify', function (string $name, string $slug): void {
    expect(Labels::slugFromName($name))->toBe($slug);
})->with([
    'plain' => ['Kampung', 'kampung'],
    'digit and punctuation' => ['Kampung 2!', 'kampung-2'],
    'space' => ['Survival Utama', 'survival-utama'],
    'only punctuation' => ['!!!', ''],
    'runs collapse' => ['a   --  b', 'a-b'],
    'edge hyphens' => ['--a--', 'a'],
    'non-ascii letters' => ['Kampung Ünï', 'kampung-n'],
    'kelvin sign lower-cases to k' => ["\u{212A}amp", 'kamp'],
    'dotted capital i' => ["\u{130}stanbul", 'i-stanbul'],
    'long name cut to 40' => [str_repeat('a', 60), str_repeat('a', 40)],
    'cut does not leave a hyphen' => [str_repeat('a', 39).' b', str_repeat('a', 39)],
]);

test('a non-empty slug is always a valid label', function (string $name): void {
    $slug = Labels::slugFromName($name);
    expect($slug === '' || Labels::problem($slug, []) === null)->toBeTrue();
})->with(['Kampung 2!', 'Survival Utama', 'Kampung Ünï', "\u{212A}amp", str_repeat('a', 60), str_repeat('a', 39).' b']);
