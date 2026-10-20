<?php

declare(strict_types=1);

use OauthLogin\Tests\ExtensionTestCase;
use Pterodactyl\Models\ExtensionSetting;
use Pterodactyl\Models\User;

uses(ExtensionTestCase::class);

// FR-O1, NFR-O2, NFR-O4, AC-O19 (server half), EC-O10: the settings form, secrecy and what guests can read.

function settingsUrl(): string
{
    return route('api.admin.extensions.settings', ['extension' => 'oauth-login']);
}

function updateUrl(): string
{
    return route('api.admin.extensions.settings.update', ['extension' => 'oauth-login']);
}

test('the settings form has exactly the documented fields, in four tabs, and no URL setting (NFR-O4)', function (): void {
    $schema = $this->actingAs(User::factory()->create(['root_admin' => true]))->getJson(settingsUrl())->assertOk()->json('data.schema');

    expect(array_column($schema, 'input'))->toBe([
        'enabled_providers', 'allow_registration', 'allow_admin_login', 'two_factor_policy',
        'discord_client_id', 'discord_client_secret', 'github_client_id', 'github_client_secret', 'google_client_id', 'google_client_secret',
    ]);
    expect(array_values(array_unique(array_column($schema, 'tab'))))->toBe(['General', 'Discord', 'GitHub', 'Google']);
    expect(collect($schema)->pluck('value')->filter(fn ($v) => is_string($v) && str_starts_with($v, 'http'))->all())->toBe([]);
});

test('NFR-O2 a stored client secret is shown as the mask, never as its value', function (): void {
    $this->enableProvider('discord');

    $response = $this->actingAs(User::factory()->create(['root_admin' => true]))->getJson(settingsUrl())->assertOk();

    $field = collect($response->json('data.schema'))->firstWhere('input', 'discord_client_secret');
    expect($field['value'])->toBe('********')->and($field['field'])->toBe('password');
    expect($response->getContent())->not->toContain('S3CRET-discord');
});

test('NFR-O2 a client secret is encrypted at rest', function (): void {
    $this->enableProvider('discord');

    $row = ExtensionSetting::query()->where('extension', 'oauth-login')->where('key', 'discord_client_secret')->sole();

    expect($row->is_secret)->toBeTrue()
        ->and($row->value)->not->toContain('S3CRET-discord');
});

test('saving the form with the mask keeps the stored secret', function (): void {
    $this->enableProvider('discord');
    $admin = User::factory()->create(['root_admin' => true]);

    $this->actingAs($admin)->patchJson(updateUrl(), ['settings' => ['discord_client_secret' => '********', 'allow_registration' => true]])->assertOk();

    $this->app->forgetInstance(\Pterodactyl\Services\Extensions\ExtensionSettingsRegistry::class);
    expect(ExtensionSetting::query()->where('key', 'discord_client_secret')->count())->toBe(1);
    // The credentials still work: the redirect is built with the stored client id.
    $this->get('/extensions/oauth-login/redirect/discord')->assertStatus(302);
});

test('only administrators can read or change the settings', function (): void {
    $this->getJson(settingsUrl())->assertUnauthorized();
    $this->patchJson(updateUrl(), ['settings' => ['allow_registration' => true]])->assertUnauthorized();

    $user = User::factory()->create();
    $this->actingAs($user)->getJson(settingsUrl())->assertForbidden();
    $this->actingAs($user)->patchJson(updateUrl(), ['settings' => ['allow_registration' => true]])->assertForbidden();
});

test('the form rejects values that could be abused', function (array $settings, string $field): void {
    $response = $this->actingAs(User::factory()->create(['root_admin' => true]))->patchJson(updateUrl(), ['settings' => $settings])->assertUnprocessable();

    expect(collect($response->json('errors'))->pluck('meta.source_field')->all())->toContain($field);
})->with([
    'client id with spaces' => [['discord_client_id' => 'abc def'], 'discord_client_id'],
    'client id with a quote' => [['discord_client_id' => 'abc"def'], 'discord_client_id'],
    'client id that is a URL' => [['github_client_id' => 'https://evil.example/x'], 'github_client_id'],
    'client id too long' => [['google_client_id' => str_repeat('a', 256)], 'google_client_id'],
    'secret with a space' => [['discord_client_secret' => 'a b'], 'discord_client_secret'],
    'secret with a newline' => [['github_client_secret' => "abc\ndef"], 'github_client_secret'],
    'secret too long' => [['google_client_secret' => str_repeat('a', 513)], 'google_client_secret'],
    'unknown provider enabled' => [['enabled_providers' => ['gitlab']], 'enabled_providers.0'],
    'policy outside the choices' => [['two_factor_policy' => 'ignore'], 'two_factor_policy'],
    'toggle that is not a boolean' => [['allow_admin_login' => 'yes please'], 'allow_admin_login'],
]);

test('AC-O19 guests receive only the list of enabled providers', function (): void {
    $this->enableProvider('discord', ['allow_registration' => true, 'allow_admin_login' => true]);

    $html = (string) $this->get('/auth/login')->assertOk()->assertSee('"id":"oauth-login"', false)->getContent();

    expect($html)->toContain('"config":{"enabled_providers":["discord"]}')
        ->not->toContain('S3CRET-discord')
        ->not->toContain('client-id-discord')
        ->not->toContain('allow_registration')
        ->not->toContain('allow_admin_login');
});

test('FR-O1 EC-O10 a secret that is empty in storage makes the provider unavailable', function (): void {
    $this->enableProvider('discord');
    $this->app->make(\Pterodactyl\Services\Extensions\ExtensionRepository::class)->settings('oauth-login')->setSecret('discord_client_secret', '');

    $this->get('/extensions/oauth-login/redirect/discord')->assertRedirect('/auth/login?oauth_error=provider_unavailable');
});

test('every option the form offers is something the code understands', function (): void {
    $schema = $this->actingAs(User::factory()->create(['root_admin' => true]))->getJson(settingsUrl())->json('data.schema');
    $providers = collect($schema)->firstWhere('input', 'enabled_providers')['options'];
    $policies = collect($schema)->firstWhere('input', 'two_factor_policy')['options'];

    expect(array_column($providers, 'value'))->toBe(array_map(fn ($p) => $p->value, OauthLogin\Support\Provider::cases()))
        ->and(array_column($policies, 'value'))->toBe(['block', 'trust_provider']);
});
