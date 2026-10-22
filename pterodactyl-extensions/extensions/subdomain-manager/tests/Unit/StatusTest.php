<?php

declare(strict_types=1);

use SubdomainManager\Support\Status;

// FR-R5, AC-R7, EC-R1, NFR-R1: the address status is worked out from Panel data only, with the same rules as
// `build_routes` in lib/games.py, so the page never says "will be routed" for a server that is not.

test('a Minecraft server on a loopback allocation with a usable name will be routed', function (?string $ip): void {
    expect(Status::evaluate(true, false, $ip, 'kampung', false))->toBe(['state' => 'ready', 'reason' => null]);
})->with(['127.0.0.1', 'localhost']);

test('servers that are not Minecraft get no routing status at all', function (): void {
    expect(Status::evaluate(false, false, '127.0.0.1', 'kampung', false))->toBeNull();
});

test('a suspended server is not routed', function (): void {
    expect(Status::evaluate(true, true, '127.0.0.1', 'kampung', false))
        ->toBe(['state' => 'invalid', 'reason' => 'the server is suspended']);
});

test('AC-R7 an allocation that is not on loopback is refused with the address in the reason', function (): void {
    expect(Status::evaluate(true, false, '0.0.0.0', 'kampung', false))
        ->toBe(['state' => 'invalid', 'reason' => 'the allocation is 0.0.0.0, not 127.0.0.1']);
});

test('an allocation the Panel does not show is refused, and the reason says so', function (): void {
    expect(Status::evaluate(true, false, null, 'kampung', false))
        ->toBe(['state' => 'invalid', 'reason' => 'the allocation is not visible']);
});

test('EC-R1 a name that gives no host name is refused, and nothing is routed as ".mc.domain"', function (): void {
    expect(Status::evaluate(true, false, '127.0.0.1', '', false))
        ->toBe(['state' => 'invalid', 'reason' => 'the name does not give a host name']);
});

test('a host name another server already has is refused', function (): void {
    expect(Status::evaluate(true, false, '127.0.0.1', 'kampung', true))
        ->toBe(['state' => 'invalid', 'reason' => 'another server already has this host name']);
});

test('a slug is taken when another server name gives the same slug, whatever the spelling', function (): void {
    expect(Status::slugTaken('survival-utama', ['Survival Utama']))->toBeTrue()
        ->and(Status::slugTaken('survival-utama', ['survival-utama!']))->toBeTrue()
        ->and(Status::slugTaken('survival-utama', ['Survival Mode']))->toBeFalse()
        ->and(Status::slugTaken('', ['!!!']))->toBeFalse();
});
