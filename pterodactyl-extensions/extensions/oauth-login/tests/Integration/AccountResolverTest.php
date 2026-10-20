<?php

declare(strict_types=1);

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Notification;
use Illuminate\Validation\ValidationException;
use OauthLogin\Models\Identity;
use OauthLogin\Support\AccountResolver;
use OauthLogin\Support\OauthSettings;
use OauthLogin\Support\Profile;
use OauthLogin\Support\Provider;
use OauthLogin\Tests\ExtensionTestCase;
use Pterodactyl\Contracts\Users\CreatesUsers;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

uses(ExtensionTestCase::class);

// EC-O3, EC-O4: the resolver under concurrent callbacks, simulated by letting "the other request"
// win at the exact moment between our lookup and our write.

function profile(string $id = '777', string $email = 'racer@example.test'): Profile
{
    return new Profile($id, $email, 'racer', 'Racer One');
}

function resolver(): AccountResolver
{
    return app(AccountResolver::class);
}

function oauthSettings(): OauthSettings
{
    return OauthSettings::fromRegistry(app(ExtensionSettingsRegistry::class));
}

beforeEach(function (): void {
    Notification::fake();
    $this->configure(['allow_registration' => true]);
});

test('EC-O4 a parallel request that created the same user first: the loser links to it instead of failing', function (): void {
    $real = app(CreatesUsers::class);
    app()->instance(CreatesUsers::class, new class($real) implements CreatesUsers
    {
        public function __construct(private CreatesUsers $real) {}

        public function create(array $input): User
        {
            $this->real->create($input); // the winning request
            throw ValidationException::withMessages(['email' => 'The email has already been taken.']);
        }
    });

    $resolution = resolver()->resolve(Provider::Discord, profile(), oauthSettings());

    expect($resolution->error)->toBeNull()
        ->and($resolution->user->email)->toBe('racer@example.test')
        ->and($resolution->linked)->toBeTrue()
        ->and($resolution->created)->toBeFalse();
    expect(User::query()->where('email', 'racer@example.test')->count())->toBe(1)
        ->and(Identity::query()->count())->toBe(1);
});

test('EC-O4 a parallel request that linked the same identity first: the loser reuses it', function (): void {
    $user = User::factory()->create(['email' => 'racer@example.test']);
    $armed = true;
    Identity::creating(function () use (&$armed, $user): void {
        if ($armed) {
            $armed = false;
            DB::table('ext_oauth_login_identities')->insert(['user_id' => $user->id, 'provider' => 'discord', 'provider_user_id' => '777', 'created_at' => now()]);
        }
    });

    $resolution = resolver()->resolve(Provider::Discord, profile(), oauthSettings());

    expect($resolution->error)->toBeNull()
        ->and($resolution->user->is($user))->toBeTrue();
    expect(Identity::query()->count())->toBe(1);
});

test('EC-O4 a race lost on the one identity per provider rule ends as identity_conflict, not a crash', function (): void {
    $user = User::factory()->create(['email' => 'racer@example.test']);
    $armed = true;
    Identity::creating(function () use (&$armed, $user): void {
        if ($armed) {
            $armed = false;
            // Another browser linked a different Discord account to this user a moment ago.
            DB::table('ext_oauth_login_identities')->insert(['user_id' => $user->id, 'provider' => 'discord', 'provider_user_id' => 'someone-else', 'created_at' => now()]);
        }
    });

    $resolution = resolver()->resolve(Provider::Discord, profile(), oauthSettings());

    expect($resolution->user)->toBeNull()->and($resolution->error)->toBe('identity_conflict');
    expect(Identity::query()->pluck('provider_user_id')->all())->toBe(['someone-else']);
});

test('EC-O3 when the Panel keeps refusing the new user the answer is registration_failed', function (): void {
    app()->instance(CreatesUsers::class, new class implements CreatesUsers
    {
        public function create(array $input): User
        {
            throw ValidationException::withMessages(['email' => 'refused']);
        }
    });

    $resolution = resolver()->resolve(Provider::Discord, profile(), oauthSettings());

    expect($resolution->user)->toBeNull()->and($resolution->error)->toBe('registration_failed');
    expect(Identity::query()->count())->toBe(0);
});

test('the same provider id under two providers are two identities', function (): void {
    $user = User::factory()->create(['email' => 'racer@example.test']);

    resolver()->resolve(Provider::Discord, profile('42'), oauthSettings());
    resolver()->resolve(Provider::Github, profile('42'), oauthSettings());

    expect(Identity::query()->where('user_id', $user->id)->orderBy('provider')->pluck('provider')->all())->toBe(['discord', 'github']);
});

test('provider ids are compared exactly: case differences are different accounts', function (): void {
    $user = User::factory()->create(['email' => 'one@example.test']);
    Identity::query()->create(['user_id' => $user->id, 'provider' => 'google', 'provider_user_id' => 'AbC']);

    // A different user on "abc" must not be treated as the account linked to "AbC".
    $other = resolver()->resolve(Provider::Google, profile('abc', 'two@example.test'), oauthSettings());

    expect($other->created)->toBeTrue()
        ->and($other->user->is($user))->toBeFalse();
});

test('a new user is never an administrator, even if the profile says admin-like things', function (): void {
    $resolution = resolver()->resolve(Provider::Discord, new Profile('9', 'admin@example.test', 'admin', 'Root Admin'), oauthSettings());

    expect((bool) $resolution->user->root_admin)->toBeFalse();
});
