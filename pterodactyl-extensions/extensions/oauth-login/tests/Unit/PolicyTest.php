<?php

declare(strict_types=1);

use OauthLogin\Support\Policy;

// FR-O9, AC-O11, AC-O12. Full truth table: admin x totp x allow_admin_login x policy.
// Any policy value other than "trust_provider" blocks (fail closed).

dataset('policy table', function (): Generator {
    foreach ([false, true] as $admin) {
        foreach ([false, true] as $totp) {
            foreach ([false, true] as $allowAdmin) {
                foreach (['block', 'trust_provider', 'garbage', ''] as $policy) {
                    $expected = match (true) {
                        $admin && ! $allowAdmin => 'admin_blocked',
                        $totp && $policy !== 'trust_provider' => 'two_factor_required',
                        default => null,
                    };
                    yield sprintf('admin=%d totp=%d allow_admin=%d policy=%s', $admin, $totp, $allowAdmin, $policy ?: 'empty') => [$admin, $totp, $allowAdmin, $policy, $expected];
                }
            }
        }
    }
});

test('policy truth table', function (bool $admin, bool $totp, bool $allowAdmin, string $policy, ?string $expected): void {
    expect(Policy::check($admin, $totp, $allowAdmin, $policy))->toBe($expected);
})->with('policy table');

test('AC-O11 an administrator is refused first, even when 2FA would also have refused', function (): void {
    expect(Policy::check(true, true, false, 'block'))->toBe('admin_blocked');
});

test('a plain user with no 2FA always passes', function (string $policy): void {
    expect(Policy::check(false, false, false, $policy))->toBeNull();
})->with(['block', 'trust_provider', 'garbage']);
