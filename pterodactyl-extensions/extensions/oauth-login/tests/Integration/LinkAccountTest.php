<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Http;
use OauthLogin\Models\Identity;
use OauthLogin\Tests\ExtensionTestCase;
use Pterodactyl\Models\User;

uses(ExtensionTestCase::class);

// "Connect this account" for a signed-in user: GET /link/{provider} starts a flow that remembers the user, the
// shared callback attaches the provider account to that user and signs nobody in. Results go to the account page.

const ACCOUNT = '/account/connected-accounts';

function linkCallback(array $query = []): string
{
    return '/extensions/oauth-login/callback/discord?'.http_build_query(['code' => 'AUTH-CODE-123', ...$query]);
}

beforeEach(function (): void {
    $this->enableProvider('discord');
    $this->fakeDiscord();
    $this->owner = User::factory()->create(['email' => 'owner@panel.test']);
});

describe('starting', function (): void {
    test('a signed-in user is sent to the provider with a state, and the flow remembers the user', function (): void {
        $location = $this->actingAs($this->owner)->get('/extensions/oauth-login/link/discord')->assertStatus(302)->headers->get('Location');

        expect($location)->toStartWith('https://discord.com/oauth2/authorize?');
        parse_str((string) parse_url($location, PHP_URL_QUERY), $query);
        expect(session('oauth-login.flow'))->toMatchArray(['state' => $query['state'], 'uid' => $this->owner->id, 'provider' => 'discord']);
    });

    test('a guest is not sent to a provider: the route needs a signed-in user', function (): void {
        $response = $this->get('/extensions/oauth-login/link/discord');

        expect((string) $response->headers->get('Location'))->not->toContain('discord.com');
        expect(session()->has('oauth-login.flow'))->toBeFalse();
    });

    test('a provider that is off goes back to the account page', function (): void {
        $this->configure(['enabled_providers' => []]);

        $this->actingAs($this->owner)->get('/extensions/oauth-login/link/discord')->assertRedirect(ACCOUNT.'?oauth_error=provider_unavailable');
    });

    test('an unknown provider is a 404', function (): void {
        $this->actingAs($this->owner)->get('/extensions/oauth-login/link/gitlab')->assertNotFound();
    });

    test('FR-O15 it shares the 20 per minute limit', function (): void {
        $this->actingAs($this->owner);
        for ($i = 0; $i < 20; $i++) {
            $this->get('/extensions/oauth-login/link/discord')->assertStatus(302);
        }

        $this->get('/extensions/oauth-login/link/discord')->assertStatus(429);
    });
});

describe('finishing', function (): void {
    function startLink($test, ?User $as = null): string
    {
        $location = $test->actingAs($as ?? $test->owner)->get('/extensions/oauth-login/link/discord')->headers->get('Location');
        parse_str((string) parse_url($location, PHP_URL_QUERY), $query);

        return $query['state'];
    }

    test('the provider account is attached to the signed-in user, whatever its email, and nobody is signed in or created', function (): void {
        $state = startLink($this);
        $before = User::query()->count();

        $this->get(linkCallback(['state' => $state]))->assertRedirect(ACCOUNT.'?oauth_linked=discord');

        $this->assertDatabaseHas('ext_oauth_login_identities', ['user_id' => $this->owner->id, 'provider' => 'discord', 'provider_user_id' => '80351110224678912']);
        expect(User::query()->count())->toBe($before);
        $this->assertAuthenticatedAs($this->owner);
        $this->assertActivityOn('oauth-login:link', $this->owner);
    });

    test('allow_registration does not matter: connecting never creates a user', function (): void {
        $this->configure(['allow_registration' => true]);
        $before = User::query()->count();
        $state = startLink($this);

        $this->get(linkCallback(['state' => $state]))->assertRedirect(ACCOUNT.'?oauth_linked=discord');

        expect(User::query()->count())->toBe($before);
    });

    test('an administrator or a 2FA user may connect an account: the sign-in policy governs signing in only', function (string $flag): void {
        $user = User::factory()->create([$flag => true]);
        $state = startLink($this, $user);

        $this->get(linkCallback(['state' => $state]))->assertRedirect(ACCOUNT.'?oauth_linked=discord');

        expect(Identity::query()->where('user_id', $user->id)->exists())->toBeTrue();
    })->with(['root_admin', 'use_totp']);

    test('connecting the same provider account twice is fine and keeps one row', function (): void {
        Identity::query()->create(['user_id' => $this->owner->id, 'provider' => 'discord', 'provider_user_id' => '80351110224678912']);
        $state = startLink($this);

        $this->get(linkCallback(['state' => $state]))->assertRedirect(ACCOUNT.'?oauth_linked=discord');

        expect(Identity::query()->count())->toBe(1);
    });

    test('FR-O10 a provider account that belongs to another user is a conflict, and nothing changes', function (): void {
        $other = User::factory()->create();
        Identity::query()->create(['user_id' => $other->id, 'provider' => 'discord', 'provider_user_id' => '80351110224678912']);
        $state = startLink($this);

        $this->get(linkCallback(['state' => $state]))->assertRedirect(ACCOUNT.'?oauth_error=identity_conflict');

        expect(Identity::query()->pluck('user_id')->all())->toBe([$other->id]);
    });

    test('FR-O10 a user who already connected a different account of that provider cannot add a second', function (): void {
        Identity::query()->create(['user_id' => $this->owner->id, 'provider' => 'discord', 'provider_user_id' => 'someone-else']);
        $state = startLink($this);

        $this->get(linkCallback(['state' => $state]))->assertRedirect(ACCOUNT.'?oauth_error=identity_conflict');

        expect(Identity::query()->pluck('provider_user_id')->all())->toBe(['someone-else']);
    });

    test('EC-O4 a parallel connect that wins the race is handled', function (): void {
        $armed = true;
        $owner = $this->owner;
        Identity::creating(function () use (&$armed, $owner): void {
            if ($armed) {
                $armed = false;
                DB::table('ext_oauth_login_identities')->insert(['user_id' => $owner->id, 'provider' => 'discord', 'provider_user_id' => '80351110224678912', 'created_at' => now()]);
            }
        });
        $state = startLink($this);

        $this->get(linkCallback(['state' => $state]))->assertRedirect(ACCOUNT.'?oauth_linked=discord');

        expect(Identity::query()->count())->toBe(1);
    });

    test('failures of the provider end on the account page with the same fixed codes', function (string $case, string $code): void {
        $state = startLink($this);
        match ($case) {
            'denied' => $query = ['error' => 'access_denied', 'state' => $state],
            'unverified' => [$query = ['state' => $state], $this->fakeDiscord(['verified' => false])],
            'outage' => [$query = ['state' => $state], $this->fakeHttp(['https://discord.com/api/oauth2/token' => Http::response('', 500)])],
        };

        $this->get(linkCallback($query))->assertRedirect(ACCOUNT.'?oauth_error='.$code);

        expect(Identity::query()->count())->toBe(0);
    })->with([['denied', 'denied'], ['unverified', 'email_unverified'], ['outage', 'provider_error']]);

    test('a state works once, and a wrong state is refused before any provider call', function (): void {
        $state = startLink($this);

        $this->get(linkCallback(['state' => 'forged']))->assertRedirect('/auth/login?oauth_error=invalid_state');
        Http::assertNothingSent();
        $this->get(linkCallback(['state' => $state]))->assertRedirect('/auth/login?oauth_error=invalid_state');
        expect(Identity::query()->count())->toBe(0);
    });

    test('if another user is signed in when the provider returns, the flow is refused with no provider call', function (): void {
        $state = startLink($this);
        $intruder = User::factory()->create();

        $this->actingAs($intruder)->get(linkCallback(['state' => $state]))->assertRedirect(ACCOUNT.'?oauth_error=invalid_state');

        Http::assertNothingSent();
        expect(Identity::query()->count())->toBe(0);
    });

    test('if nobody is signed in any more, the user is sent to the login page and nothing is connected', function (): void {
        $state = startLink($this);
        auth()->logout();

        $this->get(linkCallback(['state' => $state]))->assertRedirect('/auth/login?oauth_error=invalid_state');

        Http::assertNothingSent();
        expect(Identity::query()->count())->toBe(0);
    });

    test('a sign-in flow cannot be used to connect: it signs in as usual', function (): void {
        $location = $this->get('/extensions/oauth-login/redirect/discord')->headers->get('Location');
        parse_str((string) parse_url($location, PHP_URL_QUERY), $query);

        $this->get(linkCallback(['state' => $query['state']]))->assertRedirect('/auth/login?oauth_error=no_account');
    });

    test('NFR-O3 no code, state, token or email in the log of a connect', function (): void {
        config(['logging.default' => 'oauth_capture', 'logging.channels.oauth_capture' => ['driver' => 'monolog', 'handler' => Monolog\Handler\TestHandler::class, 'level' => 'debug']]);
        $state = startLink($this);
        $this->get(linkCallback(['state' => $state, 'code' => 'LEAKY-CODE-1', 'error' => 'access_denied']));
        $this->get(linkCallback(['state' => 'LEAKY-STATE-2', 'code' => 'LEAKY-CODE-3']));

        $log = collect(Illuminate\Support\Facades\Log::channel('oauth_capture')->getLogger()->getHandlers()[0]->getRecords())->map(fn ($r) => $r->message.' '.json_encode($r->context))->implode("\n");

        expect($log)->toContain('mode')->not->toContain('LEAKY')->not->toContain('owner@panel.test')->not->toContain('TOKEN-discord');
    });
});
