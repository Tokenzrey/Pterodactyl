<?php

declare(strict_types=1);

use OauthLogin\Models\Identity;
use OauthLogin\Tests\ExtensionTestCase;
use Pterodactyl\Models\User;

uses(ExtensionTestCase::class);

// GET and DELETE /api/client/extensions/oauth-login/accounts: the data behind the "Connected accounts" page.

const API = '/api/client/extensions/oauth-login/accounts';

beforeEach(function (): void {
    $this->enableProvider('discord');
    $this->configure(['enabled_providers' => ['discord', 'github'], 'github_client_id' => 'gh', 'github_client_secret' => 'ghs']);
    $this->me = User::factory()->create();
});

test('guests are refused', function (): void {
    $this->getJson(API)->assertUnauthorized();
    $this->deleteJson(API.'/discord')->assertUnauthorized();
});

test('it lists the providers that can be connected, and which of them are', function (): void {
    Identity::query()->create(['user_id' => $this->me->id, 'provider' => 'discord', 'provider_user_id' => '123456789']);

    $response = $this->actingAs($this->me)->getJson(API)->assertOk();

    expect($response->json('providers'))->toMatchArray([
        ['id' => 'discord', 'label' => 'Discord', 'enabled' => true, 'linked' => true, 'linked_at' => $response->json('providers.0.linked_at')],
        ['id' => 'github', 'label' => 'GitHub', 'enabled' => true, 'linked' => false, 'linked_at' => null],
    ]);
    expect($response->json('providers.0.linked_at'))->toBeString();
    expect(array_column($response->json('providers'), 'id'))->not->toContain('google');
});

test('a provider that was switched off but is still connected stays listed so it can be disconnected', function (): void {
    $this->configure(['enabled_providers' => ['github']]);
    Identity::query()->create(['user_id' => $this->me->id, 'provider' => 'discord', 'provider_user_id' => '1']);

    $providers = $this->actingAs($this->me)->getJson(API)->json('providers');

    expect(collect($providers)->firstWhere('id', 'discord'))->toMatchArray(['enabled' => false, 'linked' => true]);
});

test('only the user\'s own connections show, and no provider id or credential is in the body', function (): void {
    $other = User::factory()->create();
    Identity::query()->create(['user_id' => $other->id, 'provider' => 'github', 'provider_user_id' => 'OTHER-USER-ID']);
    Identity::query()->create(['user_id' => $this->me->id, 'provider' => 'discord', 'provider_user_id' => 'MY-PROVIDER-ID']);

    $response = $this->actingAs($this->me)->getJson(API)->assertOk();

    expect(collect($response->json('providers'))->firstWhere('id', 'github')['linked'])->toBeFalse();
    expect($response->getContent())->not->toContain('OTHER-USER-ID')->not->toContain('MY-PROVIDER-ID')->not->toContain('S3CRET')->not->toContain('ghs')->not->toContain('client-id');
});

test('disconnecting removes the user\'s connection, logs it, and leaves everyone else alone', function (): void {
    $other = User::factory()->create();
    Identity::query()->create(['user_id' => $other->id, 'provider' => 'discord', 'provider_user_id' => 'theirs']);
    Identity::query()->create(['user_id' => $this->me->id, 'provider' => 'discord', 'provider_user_id' => 'mine']);

    $this->actingAs($this->me)->deleteJson(API.'/discord')->assertNoContent();

    expect(Identity::query()->pluck('provider_user_id')->all())->toBe(['theirs']);
    $this->assertActivityOn('oauth-login:unlink', $this->me);
});

test('disconnecting something that is not connected, or an unknown provider, is a 404', function (string $provider): void {
    $this->actingAs($this->me)->deleteJson(API.'/'.$provider)->assertNotFound();
})->with(['github', 'gitlab', 'DISCORD', '..']);

test('a user cannot disconnect another user\'s account by guessing', function (): void {
    $other = User::factory()->create();
    Identity::query()->create(['user_id' => $other->id, 'provider' => 'discord', 'provider_user_id' => 'theirs']);

    $this->actingAs($this->me)->deleteJson(API.'/discord')->assertNotFound();

    expect(Identity::query()->count())->toBe(1);
});

test('after disconnecting, the provider account is matched by email again, like a first sign-in', function (): void {
    $user = User::factory()->create(['email' => 'nelly@discord.test']);
    Identity::query()->create(['user_id' => $user->id, 'provider' => 'discord', 'provider_user_id' => '80351110224678912']);
    $this->actingAs($user)->deleteJson(API.'/discord')->assertNoContent();

    $resolution = app(OauthLogin\Support\AccountResolver::class)->resolve(
        OauthLogin\Support\Provider::Discord,
        new OauthLogin\Support\Profile('80351110224678912', 'nelly@discord.test', 'nelly', 'Nelly'),
        OauthLogin\Support\OauthSettings::fromRegistry(app(Pterodactyl\Services\Extensions\ExtensionSettingsRegistry::class)),
    );

    expect($resolution->user?->is($user))->toBeTrue()->and($resolution->linked)->toBeTrue();
    expect(Identity::query()->where('user_id', $user->id)->count())->toBe(1);
});
