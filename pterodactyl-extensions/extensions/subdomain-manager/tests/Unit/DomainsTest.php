<?php

declare(strict_types=1);

use SubdomainManager\Support\Domains;

// NFR-S6, AC-S11: "domain:zone_id" items. A zone id is 32 lower-case hex digits, a domain a plain
// host name. Broken items are skipped by parse() and listed by invalid(), never half-used.

const ZONE_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const ZONE_B = '0123456789abcdef0123456789abcdef';

test('parse maps each domain to its zone, lower-casing the domain', function (): void {
    expect(Domains::parse(['mc.example.com:'.ZONE_A, 'Play.Example.ORG:'.ZONE_B]))
        ->toBe(['mc.example.com' => ZONE_A, 'play.example.org' => ZONE_B]);
});

test('parse tolerates spaces around the parts', function (): void {
    expect(Domains::parse(['  mc.example.com : '.ZONE_A.'  ']))->toBe(['mc.example.com' => ZONE_A]);
});

test('NFR-S6 zone ids must be exactly 32 lower-case hex digits', function (string $zone): void {
    expect(Domains::parse(['mc.example.com:'.$zone]))->toBe([])
        ->and(Domains::invalid(['mc.example.com:'.$zone]))->toBe(['mc.example.com:'.$zone]);
})->with([
    'too short' => [substr(ZONE_A, 0, 31)],
    'too long' => [ZONE_A.'a'],
    'non hex' => [str_repeat('g', 32)],
    'upper case' => [strtoupper(ZONE_B)],
    'empty' => [''],
    'with a colon' => ['aaaaaaaaaaaaaaaa:aaaaaaaaaaaaaaaa'],
    'trailing newline' => [ZONE_A."\n"],
]);

test('NFR-S6 domains must be real host names', function (string $domain): void {
    expect(Domains::parse([$domain.':'.ZONE_A]))->toBe([])
        ->and(Domains::invalid([$domain.':'.ZONE_A]))->toHaveCount(1);
})->with([
    'single label' => ['localhost'],
    'ip address' => ['192.168.0.1'],
    'leading dot' => ['.example.com'],
    'trailing dot' => ['example.com.'],
    'empty label' => ['a..example.com'],
    'underscore' => ['my_host.example.com'],
    'leading hyphen' => ['-a.example.com'],
    'trailing hyphen' => ['a-.example.com'],
    'wildcard' => ['*.example.com'],
    'scheme' => ['https://example.com'],
    'path' => ['example.com/x'],
    'space' => ['my host.example.com'],
    'numeric tld' => ['example.123'],
    'label of 64' => [str_repeat('a', 64).'.example.com'],
    'too long for an SRV name' => [str_repeat('a.', 87).'com'],
    'empty' => [''],
]);

test('an item without a colon is invalid', function (): void {
    expect(Domains::parse(['mc.example.com']))->toBe([])
        ->and(Domains::invalid(['mc.example.com']))->toBe(['mc.example.com']);
});

test('the same domain twice is ambiguous: the first wins and the repeat is reported', function (): void {
    $items = ['mc.example.com:'.ZONE_A, 'MC.example.com:'.ZONE_B];

    expect(Domains::parse($items))->toBe(['mc.example.com' => ZONE_A])
        ->and(Domains::invalid($items))->toBe(['MC.example.com:'.ZONE_B]);
});

test('non-string items are reported and skipped', function (): void {
    $items = [5, null, ['x'], 'mc.example.com:'.ZONE_A];

    expect(Domains::parse($items))->toBe(['mc.example.com' => ZONE_A])
        ->and(Domains::invalid($items))->toHaveCount(3);
});

test('a good list reports nothing invalid', function (): void {
    expect(Domains::invalid(['mc.example.com:'.ZONE_A, 'example.org:'.ZONE_B]))->toBe([]);
});

test('names lists the configured domains only', function (): void {
    expect(Domains::names(['b.example.com:'.ZONE_A, 'broken', 'a.example.com:'.ZONE_B]))->toBe(['b.example.com', 'a.example.com']);
});

test('a plain host name check, usable on its own', function (): void {
    expect(Domains::isHostname('mc.example.com'))->toBeTrue()
        ->and(Domains::isHostname('example.com'))->toBeTrue()
        ->and(Domains::isHostname('xn--bcher-kva.example'))->toBeTrue()
        ->and(Domains::isHostname('Example.com'))->toBeFalse();
});
