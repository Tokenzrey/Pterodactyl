<?php

declare(strict_types=1);

use OauthLogin\Tests\ExtensionTestCase;
use Pterodactyl\Models\User;

uses(ExtensionTestCase::class);

// AC-O1 to AC-O4, AC-O17, AC-O18, EC-O5, EC-O7, FR-O2, FR-O3, FR-O4, FR-O15.

function redirectQuery(string $location): array
{
    parse_str((string) parse_url($location, PHP_URL_QUERY), $query);

    return $query;
}

test('AC-O1 Discord redirects to the authorize URL with state and a redirect_uri from APP_URL', function (): void {
    $this->enableProvider('discord');

    $response = $this->get('/extensions/oauth-login/redirect/discord')->assertStatus(302);
    $location = $response->headers->get('Location');
    $query = redirectQuery($location);

    expect($location)->toStartWith('https://discord.com/oauth2/authorize?')
        ->and($query['response_type'])->toBe('code')
        ->and($query['client_id'])->toBe('client-id-discord')
        ->and($query['scope'])->toBe('identify email')
        ->and($query['redirect_uri'])->toBe('https://panel.test/extensions/oauth-login/callback/discord')
        ->and(strlen($query['state']))->toBeGreaterThanOrEqual(22)
        ->and($query)->not->toHaveKey('code_challenge')
        ->and($location)->not->toContain('S3CRET');
    expect(session('oauth-login.flow')['state'])->toBe($query['state']);
});

test('AC-O2 GitHub and Google add an S256 code challenge', function (string $provider, string $host): void {
    $this->enableProvider($provider);

    $location = $this->get("/extensions/oauth-login/redirect/$provider")->assertStatus(302)->headers->get('Location');
    $query = redirectQuery($location);

    expect(parse_url($location, PHP_URL_HOST))->toBe($host)
        ->and($query['code_challenge_method'])->toBe('S256')
        ->and($query['code_challenge'])->toBe(rtrim(strtr(base64_encode(hash('sha256', session('oauth-login.flow')['verifier'], true)), '+/', '-_'), '='));
})->with([['github', 'github.com'], ['google', 'accounts.google.com']]);

test('AC-O3 a provider that is off, or lacks a client ID or secret, is unavailable', function (array $settings): void {
    $this->configure($settings);

    $this->get('/extensions/oauth-login/redirect/discord')->assertRedirect('/auth/login?oauth_error=provider_unavailable');
    expect(session()->has('oauth-login.flow'))->toBeFalse();
})->with([
    'not enabled' => [['discord_client_id' => 'x', 'discord_client_secret' => 'y']],
    'enabled without credentials' => [['enabled_providers' => ['discord']]],
    'enabled without secret' => [['enabled_providers' => ['discord'], 'discord_client_id' => 'x']],
    'enabled without client id' => [['enabled_providers' => ['discord'], 'discord_client_secret' => 'y']],
    'another provider is the enabled one' => [['enabled_providers' => ['github'], 'github_client_id' => 'x', 'github_client_secret' => 'y', 'discord_client_id' => 'x', 'discord_client_secret' => 'y']],
]);

test('AC-O4 FR-O2 an unknown provider is a 404', function (string $slug): void {
    $this->enableProvider('discord');

    $this->get("/extensions/oauth-login/redirect/$slug")->assertNotFound();
    $this->get("/extensions/oauth-login/callback/$slug")->assertNotFound();
})->with(['gitlab', 'Discord', 'DISCORD', 'discord%20', '..', 'discord.json']);

test('AC-O17 the Host header and forwarding headers never reach redirect_uri', function (): void {
    $this->enableProvider('discord');

    $location = $this->withHeaders(['Host' => 'evil.example', 'X-Forwarded-Host' => 'evil.example', 'X-Forwarded-Proto' => 'http'])
        ->get('/extensions/oauth-login/redirect/discord')->assertStatus(302)->headers->get('Location');

    expect(redirectQuery($location)['redirect_uri'])->toBe('https://panel.test/extensions/oauth-login/callback/discord');
});

test('EC-O7 redirect_uri keeps the https scheme of APP_URL behind a TLS-terminating proxy', function (): void {
    $this->enableProvider('discord');

    $location = $this->get('http://panel.test/extensions/oauth-login/redirect/discord')->assertStatus(302)->headers->get('Location');

    expect(redirectQuery($location)['redirect_uri'])->toStartWith('https://panel.test/');
});

test('FR-O3 a second redirect replaces the first flow', function (): void {
    $this->enableProvider('discord');

    $first = redirectQuery($this->get('/extensions/oauth-login/redirect/discord')->headers->get('Location'))['state'];
    $second = redirectQuery($this->get('/extensions/oauth-login/redirect/discord')->headers->get('Location'))['state'];

    expect($second)->not->toBe($first)->and(session('oauth-login.flow')['state'])->toBe($second);
});

test('EC-O5 someone already signed in is sent home without a new flow', function (): void {
    $this->enableProvider('discord');

    $this->actingAs(User::factory()->create())->get('/extensions/oauth-login/redirect/discord')->assertRedirect('/');
    expect(session()->has('oauth-login.flow'))->toBeFalse();
});

test('AC-O18 FR-O15 the 21st request within a minute is throttled', function (): void {
    $this->enableProvider('discord');

    for ($i = 1; $i <= 20; $i++) {
        $this->get('/extensions/oauth-login/redirect/discord')->assertStatus(302);
    }

    $this->get('/extensions/oauth-login/redirect/discord')->assertStatus(429);
    $this->get('/extensions/oauth-login/callback/discord')->assertStatus(429);
});
