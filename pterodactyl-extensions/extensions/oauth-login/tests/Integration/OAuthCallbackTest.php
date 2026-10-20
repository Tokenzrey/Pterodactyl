<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Notification;
use Monolog\Handler\TestHandler;
use OauthLogin\Models\Identity;
use OauthLogin\Tests\ExtensionTestCase;
use Pterodactyl\Models\User;
use Pterodactyl\Notifications\AccountCreated;

uses(ExtensionTestCase::class);

// AC-O5 to AC-O16, EC-O1, EC-O6, FR-O12, NFR-O3 and the "Fokus review" rows. The provider is faked
// (Http::fake with bodies shaped like the official docs); the Panel, DB, session and routes are real.

beforeEach(function (): void {
    $this->enableProvider('discord');
    $this->fakeDiscord();
});

function discordIdentity(User $user, string $id = '80351110224678912'): Identity
{
    return Identity::query()->create(['user_id' => $user->id, 'provider' => 'discord', 'provider_user_id' => $id]);
}

describe('state and flow (AC-O5, AC-O6, AC-O7, AC-O16)', function (): void {
    test('AC-O5 no flow in the session', function (): void {
        $this->returnFromProvider('discord', ['code' => 'c', 'state' => 'whatever'])->assertRedirect('/auth/login?oauth_error=invalid_state');

        Http::assertNothingSent();
        $this->assertGuest();
    });

    test('AC-O5 wrong state', function (): void {
        $this->beginFlow();

        $this->returnFromProvider('discord', ['code' => 'c', 'state' => 'forged'])->assertRedirect('/auth/login?oauth_error=invalid_state');

        Http::assertNothingSent();
    });

    test('AC-O5 a state that is an array or missing', function (array $query): void {
        $this->beginFlow();

        $this->returnFromProvider('discord', ['code' => 'c', ...$query])->assertRedirect('/auth/login?oauth_error=invalid_state');

        Http::assertNothingSent();
    })->with([
        'array' => [['state' => ['a', 'b']]],
        'empty' => [['state' => '']],
        'absent' => [[]],
    ]);

    test('AC-O5 expired after 600 seconds', function (): void {
        $state = $this->beginFlow();

        $this->travel(601)->seconds();
        $this->returnFromProvider('discord', ['code' => 'c', 'state' => $state])->assertRedirect('/auth/login?oauth_error=invalid_state');

        Http::assertNothingSent();
    });

    test('AC-O5 still valid after 600 seconds', function (): void {
        $state = $this->beginFlow();

        $this->travel(600)->seconds();
        $this->returnFromProvider('discord', ['code' => 'c', 'state' => $state])->assertRedirect('/auth/login?oauth_error=no_account');
    });

    test('AC-O5 a flow begun for another provider', function (): void {
        $this->enableProvider('github');
        $state = $this->beginFlow('github');

        $this->returnFromProvider('discord', ['code' => 'c', 'state' => $state])->assertRedirect('/auth/login?oauth_error=invalid_state');

        Http::assertNothingSent();
    });

    test('AC-O6 a state works once: the replay after a good sign-in is refused', function (): void {
        $user = User::factory()->create(['email' => 'nelly@discord.test']);
        $state = $this->beginFlow();

        $this->returnFromProvider('discord', ['code' => 'c', 'state' => $state])->assertRedirect('/');
        $this->assertAuthenticatedAs($user);
        Http::assertSentCount(2);

        auth()->logout();
        $this->returnFromProvider('discord', ['code' => 'c', 'state' => $state])->assertRedirect('/auth/login?oauth_error=invalid_state');

        Http::assertSentCount(2);
        $this->assertGuest();
    });

    test('Fokus-1 a parallel callback with the same state loses even when the session still holds the flow', function (): void {
        $state = $this->beginFlow();
        // The winner of the race has marked the state as used; this request still sees the flow in its stale session copy.
        Cache::put('oauth-login:state:'.hash('sha256', $state), true, 600);

        $this->returnFromProvider('discord', ['code' => 'c', 'state' => $state])->assertRedirect('/auth/login?oauth_error=invalid_state');

        Http::assertNothingSent();
    });

    test('AC-O7 the provider reports access_denied', function (): void {
        $state = $this->beginFlow();

        $this->returnFromProvider('discord', ['error' => 'access_denied', 'error_description' => 'The resource owner denied the request', 'state' => $state])
            ->assertRedirect('/auth/login?oauth_error=denied');

        Http::assertNothingSent();
    });

    test('any other provider error is provider_error and its text is not forwarded', function (): void {
        $state = $this->beginFlow();

        $response = $this->returnFromProvider('discord', ['error' => 'server_error', 'error_description' => '<script>alert(1)</script>', 'state' => $state])
            ->assertRedirect('/auth/login?oauth_error=provider_error');

        expect($response->headers->get('Location'))->not->toContain('script');
    });

    test('AC-O7 an error response with a bad state is still invalid_state', function (): void {
        $this->returnFromProvider('discord', ['error' => 'access_denied', 'state' => 'forged'])->assertRedirect('/auth/login?oauth_error=invalid_state');
    });

    test('AC-O16 a Discord response from another issuer is refused before any provider call', function (mixed $iss): void {
        $this->signIn('discord', ['iss' => $iss])->assertRedirect('/auth/login?oauth_error=invalid_state');

        Http::assertNothingSent();
    })->with(['https://evil.example', 'http://discord.com', 'https://discord.com/', '', [['https://discord.com']]]);

    test('AC-O16 the right issuer is accepted, and a missing one is too', function (array $extra): void {
        User::factory()->create(['email' => 'nelly@discord.test']);

        $this->signIn('discord', $extra)->assertRedirect('/');
    })->with([[['iss' => 'https://discord.com']], [[]]]);

    test('a missing, array or oversized code is provider_error without any provider call', function (mixed $code): void {
        $this->returnFromProvider('discord', ['code' => $code, 'state' => $this->beginFlow()])->assertRedirect('/auth/login?oauth_error=provider_error');

        Http::assertNothingSent();
    })->with(['', [['a']], str_repeat('a', 2049)]);

    test('Fokus-2 a provider switched off between redirect and callback is unavailable, with no provider call', function (): void {
        $state = $this->beginFlow();
        $this->configure(['enabled_providers' => []]);

        $this->returnFromProvider('discord', ['code' => 'c', 'state' => $state])->assertRedirect('/auth/login?oauth_error=provider_unavailable');

        Http::assertNothingSent();
    });
});

describe('who gets in (AC-O8 to AC-O14, EC-O1, Fokus-5)', function (): void {
    test('AC-O8 a linked identity signs in a normal user', function (): void {
        $user = User::factory()->create(['email' => 'different@panel.test']);
        discordIdentity($user);

        $this->signIn()->assertRedirect('/');

        $this->assertAuthenticatedAs($user);
        expect(Identity::query()->count())->toBe(1);
    });

    test('AC-O9 a verified email matching an existing user links the account and signs in', function (): void {
        $user = User::factory()->create(['email' => 'nelly@discord.test']);

        $this->signIn()->assertRedirect('/');

        $this->assertAuthenticatedAs($user);
        $this->assertDatabaseHas('ext_oauth_login_identities', ['user_id' => $user->id, 'provider' => 'discord', 'provider_user_id' => '80351110224678912']);
        $this->assertActivityOn('oauth-login:link', $user);
    });

    test('EC-O1 emails match regardless of letter case', function (): void {
        $user = User::factory()->create(['email' => 'Nelly@Discord.TEST']);

        $this->signIn()->assertRedirect('/');

        $this->assertAuthenticatedAs($user);
    });

    test('Fokus-5 a "+tag" address is a different address: it never links to the plain one', function (): void {
        $existing = User::factory()->create(['email' => 'nelly@discord.test']);
        $this->fakeDiscord(['email' => 'nelly+evil@discord.test']);

        $this->signIn()->assertRedirect('/auth/login?oauth_error=no_account');

        $this->assertGuest();
        expect(Identity::query()->where('user_id', $existing->id)->exists())->toBeFalse();
    });

    test('AC-O10 an unverified address signs nobody in and links nothing', function (mixed $verified): void {
        User::factory()->create(['email' => 'nelly@discord.test']);
        $this->fakeDiscord(['verified' => $verified]);

        $this->signIn()->assertRedirect('/auth/login?oauth_error=email_unverified');

        $this->assertGuest();
        expect(Identity::query()->count())->toBe(0);
    })->with([false, null, 'true', 1]);

    test('AC-O10 a profile without an email', function (): void {
        $this->fakeDiscord(['email' => null]);

        $this->signIn()->assertRedirect('/auth/login?oauth_error=email_unverified');
    });

    test('AC-O11 an administrator is refused and gains no link, new or existing', function (bool $linkedAlready): void {
        $admin = User::factory()->create(['email' => 'nelly@discord.test', 'root_admin' => true]);
        if ($linkedAlready) {
            discordIdentity($admin);
        }

        $this->signIn()->assertRedirect('/auth/login?oauth_error=admin_blocked');

        $this->assertGuest();
        expect(Identity::query()->count())->toBe($linkedAlready ? 1 : 0);
    })->with([false, true]);

    test('AC-O11 an administrator can sign in when the setting allows it', function (): void {
        $admin = User::factory()->create(['email' => 'nelly@discord.test', 'root_admin' => true]);
        $this->configure(['allow_admin_login' => true]);

        $this->signIn()->assertRedirect('/');

        $this->assertAuthenticatedAs($admin);
    });

    test('AC-O12 a 2FA user is refused by default and gains no link', function (): void {
        User::factory()->create(['email' => 'nelly@discord.test', 'use_totp' => true]);

        $this->signIn()->assertRedirect('/auth/login?oauth_error=two_factor_required');

        $this->assertGuest();
        expect(Identity::query()->count())->toBe(0);
    });

    test('AC-O12 a 2FA user signs in when the administrator trusts the provider, without a checkpoint', function (): void {
        $user = User::factory()->create(['email' => 'nelly@discord.test', 'use_totp' => true]);
        $this->configure(['two_factor_policy' => 'trust_provider']);

        $this->signIn()->assertRedirect('/');

        $this->assertAuthenticatedAs($user);
        expect(session()->has('auth_confirmation_token'))->toBeFalse();
    });

    test('AC-O13 an unknown address without registration is no_account', function (): void {
        $this->signIn()->assertRedirect('/auth/login?oauth_error=no_account');

        $this->assertGuest();
        expect(User::query()->where('email', 'nelly@discord.test')->exists())->toBeFalse();
    });

    test('AC-O13 FR-O11 with registration on, a new non-admin user is created, linked and signed in', function (): void {
        Notification::fake();
        $this->configure(['allow_registration' => true]);

        $this->signIn()->assertRedirect('/');

        $user = User::query()->where('email', 'nelly@discord.test')->sole();
        expect($user->username)->toBe('nelly')
            ->and($user->name_first)->toBe('Nelly')
            ->and($user->name_last)->toBe('Furtado')
            ->and((bool) $user->root_admin)->toBeFalse()
            ->and((bool) $user->use_totp)->toBeFalse();
        $this->assertAuthenticatedAs($user);
        $this->assertDatabaseHas('ext_oauth_login_identities', ['user_id' => $user->id, 'provider' => 'discord']);
        Notification::assertSentTo($user, AccountCreated::class);
        $this->assertActivityOn('oauth-login:register', $user);
    });

    test('EC-O2 a taken username gets a random suffix', function (): void {
        Notification::fake();
        User::factory()->create(['username' => 'nelly', 'email' => 'other@panel.test']);
        $this->configure(['allow_registration' => true]);

        $this->signIn()->assertRedirect('/');

        expect(User::query()->where('email', 'nelly@discord.test')->sole()->username)->toMatch('/^nelly-[0-9a-f]{4}$/');
    });

    test('EC-O3 an address the Panel refuses is registration_failed, not a 500', function (): void {
        Notification::fake();
        $this->configure(['allow_registration' => true]);
        $this->fakeDiscord(['email' => '-evil@discord.test']);

        $this->signIn()->assertRedirect('/auth/login?oauth_error=registration_failed');

        $this->assertGuest();
        expect(User::query()->where('email', '-evil@discord.test')->exists())->toBeFalse();
    });

    test('a display name with one word gets a placeholder last name', function (): void {
        Notification::fake();
        $this->configure(['allow_registration' => true]);
        $this->fakeDiscord(['global_name' => 'Nelly']);

        $this->signIn()->assertRedirect('/');

        expect(User::query()->where('email', 'nelly@discord.test')->sole()->name_last)->toBe('-');
    });

    test('AC-O14 a second provider account with the same email cannot take over a linked user', function (): void {
        $user = User::factory()->create(['email' => 'nelly@discord.test']);
        discordIdentity($user, 'A-111');

        $this->signIn()->assertRedirect('/auth/login?oauth_error=identity_conflict');

        $this->assertGuest();
        expect(Identity::query()->where('user_id', $user->id)->pluck('provider_user_id')->all())->toBe(['A-111']);
    });

    test('EC-O9 a removed identity row falls back to matching by email', function (): void {
        $user = User::factory()->create(['email' => 'nelly@discord.test']);
        discordIdentity($user)->delete();

        $this->signIn()->assertRedirect('/');

        $this->assertAuthenticatedAs($user);
        expect(Identity::query()->where('user_id', $user->id)->count())->toBe(1);
    });

    test('a user changing their Panel email keeps signing in through the identity', function (): void {
        $user = User::factory()->create(['email' => 'moved@panel.test']);
        discordIdentity($user);

        $this->signIn()->assertRedirect('/');

        $this->assertAuthenticatedAs($user);
    });

    test('deleting the user removes the identity (cascade)', function (): void {
        $user = User::factory()->create();
        discordIdentity($user);

        $user->delete();

        expect(Identity::query()->count())->toBe(0);
    });
});

describe('provider failures (AC-O15, EC-O6)', function (): void {
    test('AC-O15 an unusable provider answer is provider_error and nobody is signed in', function (string $case): void {
        User::factory()->create(['email' => 'nelly@discord.test']);
        $this->fakeHttp([
            'https://discord.com/api/oauth2/token' => match ($case) {
                'token 500' => Http::response('boom', 500),
                'token 401' => Http::response(['error' => 'invalid_client'], 401),
                'no access_token' => Http::response(['token_type' => 'Bearer']),
                'timeout' => Http::failedConnection('cURL error 28: Operation timed out'),
                default => Http::response(['access_token' => 'T']),
            },
            'https://discord.com/api/users/@me' => $case === 'profile 500' ? Http::response('', 500) : Http::response('<html>not json</html>'),
        ]);

        $this->signIn()->assertRedirect('/auth/login?oauth_error=provider_error');

        $this->assertGuest();
        expect(Identity::query()->count())->toBe(0);
    })->with(['token 500', 'token 401', 'no access_token', 'timeout', 'profile 500', 'profile html']);

    test('GitHub signs in with the primary verified address', function (): void {
        $this->enableProvider('github');
        $user = User::factory()->create(['email' => 'octocat@github.test']);
        $this->fakeGithub();

        $this->signIn('github')->assertRedirect('/');

        $this->assertAuthenticatedAs($user);
        $this->assertDatabaseHas('ext_oauth_login_identities', ['user_id' => $user->id, 'provider' => 'github', 'provider_user_id' => '583231']);
    });

    test('EC-O6 GitHub with only a non-primary verified address is email_unverified', function (): void {
        $this->enableProvider('github');
        User::factory()->create(['email' => 'second@github.test']);
        $this->fakeGithub(emails: [['email' => 'octocat@github.test', 'primary' => true, 'verified' => false], ['email' => 'second@github.test', 'primary' => false, 'verified' => true]]);

        $this->signIn('github')->assertRedirect('/auth/login?oauth_error=email_unverified');

        $this->assertGuest();
    });

    test('Google signs in and an unverified Google address is refused', function (): void {
        $this->enableProvider('google');
        $user = User::factory()->create(['email' => 'ada@google.test']);
        $this->fakeGoogle();

        $this->signIn('google')->assertRedirect('/');
        $this->assertAuthenticatedAs($user);

        auth()->logout();
        $this->fakeGoogle(['email_verified' => false]);
        $this->signIn('google')->assertRedirect('/auth/login?oauth_error=email_unverified');
        $this->assertGuest();
    });
});

describe('what never leaves the server (FR-O12, FR-O13, NFR-O3)', function (): void {
    test('FR-O12 success always lands on the Panel home, whatever the request carries', function (): void {
        User::factory()->create(['email' => 'nelly@discord.test']);

        $response = $this->signIn('discord', ['redirect' => 'https://evil.example', 'next' => '//evil.example', 'intended' => 'https://evil.example', 'return_to' => '/admin']);

        $location = $response->headers->get('Location');
        expect(parse_url($location, PHP_URL_PATH) ?? '/')->toBe('/')
            ->and(parse_url($location, PHP_URL_QUERY))->toBeNull()
            ->and(parse_url($location, PHP_URL_HOST))->not->toBe('evil.example');
    });

    test('FR-O13 every failure redirects to the login page with a code from the fixed list', function (): void {
        $codes = [];
        foreach ([
            fn () => $this->returnFromProvider('discord', ['state' => 'x', 'code' => 'c']),
            fn () => $this->returnFromProvider('discord', ['state' => $this->beginFlow(), 'error' => 'access_denied']),
            fn () => $this->signIn(),
        ] as $attempt) {
            $location = $attempt()->headers->get('Location');
            parse_str((string) parse_url($location, PHP_URL_QUERY), $query);
            expect(parse_url($location, PHP_URL_PATH))->toBe('/auth/login');
            $codes[] = $query['oauth_error'];
        }

        expect($codes)->toHaveCount(3);
        foreach ($codes as $code) {
            expect(OauthLogin\Support\Errors::ALL)->toContain($code);
        }
    });

    test('NFR-O3 logs never contain the code, state, token, client secret or an email address', function (): void {
        config(['logging.default' => 'oauth_capture', 'logging.channels.oauth_capture' => ['driver' => 'monolog', 'handler' => TestHandler::class, 'level' => 'debug']]);
        User::factory()->create(['email' => 'nelly@discord.test', 'use_totp' => true]);

        // A spread of outcomes: refused 2FA user, bad state, provider denial, provider failure.
        $this->signIn('discord', ['code' => 'LEAKY-CODE-777'])->assertRedirect('/auth/login?oauth_error=two_factor_required');
        $this->returnFromProvider('discord', ['code' => 'LEAKY-CODE-777', 'state' => 'LEAKY-STATE-888'])->assertRedirect('/auth/login?oauth_error=invalid_state');
        $this->returnFromProvider('discord', ['error' => 'access_denied', 'error_description' => 'LEAKY-DESC', 'state' => $this->beginFlow()]);
        $this->fakeHttp(['https://discord.com/api/oauth2/token' => Http::response('', 500)]);
        $this->signIn('discord', ['code' => 'LEAKY-CODE-999']);

        $records = collect(Log::channel('oauth_capture')->getLogger()->getHandlers()[0]->getRecords())
            ->map(fn ($record) => $record->message.' '.json_encode($record->context, JSON_THROW_ON_ERROR))->implode("\n");

        expect($records)->toContain('oauth-login: sign-in failed');
        foreach (['LEAKY-CODE', 'LEAKY-STATE', 'LEAKY-DESC', 'TOKEN-discord', 'S3CRET-discord', 'nelly@discord.test', 'client-id-discord'] as $secret) {
            expect($records)->not->toContain($secret);
        }
    });

    test('NFR-O3 the access token is never kept: not in the session, not in the database', function (): void {
        User::factory()->create(['email' => 'nelly@discord.test']);

        $this->signIn()->assertRedirect('/');

        expect(json_encode(session()->all(), JSON_THROW_ON_ERROR))->not->toContain('TOKEN-discord');
        expect(json_encode(Identity::query()->get()->toArray(), JSON_THROW_ON_ERROR))->not->toContain('TOKEN-discord');
    });
});
