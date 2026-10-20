<?php

declare(strict_types=1);

use OauthLogin\Support\Provider;

// FR-O1, NFR-O4: exactly three providers, all endpoints are HTTPS constants in code.

test('there are exactly three providers with fixed slugs', function (): void {
    expect(array_map(fn (Provider $p): string => $p->value, Provider::cases()))
        ->toBe(['discord', 'github', 'google']);
});

test('slug lookup is exact: case, whitespace and path tricks do not match', function (string $slug): void {
    expect(Provider::tryFrom($slug))->toBeNull();
})->with(['Discord', 'GITHUB', ' google', 'google ', '', '../discord', 'discord/', 'gitlab', "discord\0"]);

test('endpoints match the specification table', function (): void {
    expect(Provider::Discord->authorizeUrl())->toBe('https://discord.com/oauth2/authorize')
        ->and(Provider::Discord->tokenUrl())->toBe('https://discord.com/api/oauth2/token')
        ->and(Provider::Discord->profileUrl())->toBe('https://discord.com/api/users/@me')
        ->and(Provider::Discord->emailsUrl())->toBeNull()
        ->and(Provider::Github->authorizeUrl())->toBe('https://github.com/login/oauth/authorize')
        ->and(Provider::Github->tokenUrl())->toBe('https://github.com/login/oauth/access_token')
        ->and(Provider::Github->profileUrl())->toBe('https://api.github.com/user')
        ->and(Provider::Github->emailsUrl())->toBe('https://api.github.com/user/emails')
        ->and(Provider::Google->authorizeUrl())->toBe('https://accounts.google.com/o/oauth2/v2/auth')
        ->and(Provider::Google->tokenUrl())->toBe('https://oauth2.googleapis.com/token')
        ->and(Provider::Google->profileUrl())->toBe('https://openidconnect.googleapis.com/v1/userinfo')
        ->and(Provider::Google->emailsUrl())->toBeNull();
});

test('every endpoint is HTTPS on a fixed host', function (): void {
    $hosts = ['discord.com', 'github.com', 'api.github.com', 'accounts.google.com', 'oauth2.googleapis.com', 'openidconnect.googleapis.com'];
    foreach (Provider::cases() as $provider) {
        foreach (array_filter([$provider->authorizeUrl(), $provider->tokenUrl(), $provider->profileUrl(), $provider->emailsUrl()]) as $url) {
            expect(parse_url($url, PHP_URL_SCHEME))->toBe('https')
                ->and($hosts)->toContain(parse_url($url, PHP_URL_HOST));
        }
    }
});

test('scopes are the minimum each provider needs', function (): void {
    expect(Provider::Discord->scopes())->toBe('identify email')
        ->and(Provider::Github->scopes())->toBe('read:user user:email')
        ->and(Provider::Google->scopes())->toBe('openid email profile');
});

test('PKCE is used for GitHub and Google, not for Discord', function (): void {
    expect(Provider::Discord->usesPkce())->toBeFalse()
        ->and(Provider::Github->usesPkce())->toBeTrue()
        ->and(Provider::Google->usesPkce())->toBeTrue();
});

test('only Discord carries an issuer to check on the callback (AC-O16)', function (): void {
    expect(Provider::Discord->issuer())->toBe('https://discord.com')
        ->and(Provider::Github->issuer())->toBeNull()
        ->and(Provider::Google->issuer())->toBeNull();
});

test('labels are human readable', function (): void {
    expect(array_map(fn (Provider $p): string => $p->label(), Provider::cases()))
        ->toBe(['Discord', 'GitHub', 'Google']);
});
