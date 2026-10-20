<?php

declare(strict_types=1);

use Illuminate\Session\ArraySessionHandler;
use Illuminate\Session\Store;
use OauthLogin\Support\AuthUrl;
use OauthLogin\Support\Flow;
use OauthLogin\Support\Provider;

// FR-O3, FR-O5, FR-O4. Uses the real session Store on an in-memory handler: no framework boot needed.

function memorySession(): Store
{
    return new Store('test', new ArraySessionHandler(120));
}

const T0 = 1_800_000_000;

test('AC-O1 start makes an unguessable url-safe state', function (): void {
    $flow = Flow::start(memorySession(), Provider::Discord, T0);

    expect(strlen($flow->state))->toBeGreaterThanOrEqual(22)
        ->and($flow->state)->toMatch('/^[A-Za-z0-9_-]+$/');
});

test('two flows never share a state', function (): void {
    $states = array_map(fn (): string => Flow::start(memorySession(), Provider::Discord, T0)->state, range(1, 50));
    expect(array_unique($states))->toHaveCount(50);
});

test('AC-O1 Discord has no PKCE material', function (): void {
    $flow = Flow::start(memorySession(), Provider::Discord, T0);
    expect($flow->verifier)->toBeNull()->and($flow->challenge())->toBeNull();
});

test('AC-O2 GitHub and Google get a PKCE verifier of valid length and an S256 challenge', function (Provider $provider): void {
    $flow = Flow::start(memorySession(), $provider, T0);

    expect(strlen($flow->verifier))->toBeBetween(43, 128)
        ->and($flow->verifier)->toMatch('/^[A-Za-z0-9_-]+$/')
        ->and($flow->challenge())->toBe(rtrim(strtr(base64_encode(hash('sha256', $flow->verifier, true)), '+/', '-_'), '='));
})->with([Provider::Github, Provider::Google]);

test('the challenge matches the RFC 7636 appendix B vector', function (): void {
    $flow = new Flow(Provider::Github, 'state', 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk', T0);
    expect($flow->challenge())->toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
});

test('consume returns the flow that start made', function (): void {
    $session = memorySession();
    $started = Flow::start($session, Provider::Github, T0);
    $consumed = Flow::consume($session, Provider::Github, $started->state, T0 + 5);

    expect($consumed)->not->toBeNull()
        ->and($consumed->state)->toBe($started->state)
        ->and($consumed->verifier)->toBe($started->verifier);
});

test('AC-O6 a state works exactly once', function (): void {
    $session = memorySession();
    $flow = Flow::start($session, Provider::Discord, T0);

    expect(Flow::consume($session, Provider::Discord, $flow->state, T0 + 1))->not->toBeNull()
        ->and(Flow::consume($session, Provider::Discord, $flow->state, T0 + 2))->toBeNull();
});

test('AC-O5 a wrong state fails and still burns the flow', function (): void {
    $session = memorySession();
    $flow = Flow::start($session, Provider::Discord, T0);

    expect(Flow::consume($session, Provider::Discord, 'not-the-state', T0 + 1))->toBeNull()
        ->and(Flow::consume($session, Provider::Discord, $flow->state, T0 + 2))->toBeNull();
});

test('AC-O5 empty, truncated and padded states fail without errors', function (string $bad): void {
    $session = memorySession();
    $flow = Flow::start($session, Provider::Discord, T0);
    $candidate = match ($bad) {
        'truncated' => substr($flow->state, 0, -1),
        'padded' => $flow->state.'A',
        default => $bad,
    };

    expect(Flow::consume($session, Provider::Discord, $candidate, T0 + 1))->toBeNull();
})->with(['', 'truncated', 'padded']);

test('AC-O5 no flow in the session fails', function (): void {
    expect(Flow::consume(memorySession(), Provider::Discord, 'anything', T0))->toBeNull();
});

test('AC-O5 the flow is valid for 600 seconds and not one second more', function (): void {
    $session = memorySession();
    $flow = Flow::start($session, Provider::Discord, T0);
    expect(Flow::consume($session, Provider::Discord, $flow->state, T0 + 600))->not->toBeNull();

    $session = memorySession();
    $flow = Flow::start($session, Provider::Discord, T0);
    expect(Flow::consume($session, Provider::Discord, $flow->state, T0 + 601))->toBeNull();
});

test('AC-O5 a flow started for another provider cannot be consumed (and is burned)', function (): void {
    $session = memorySession();
    $flow = Flow::start($session, Provider::Discord, T0);

    expect(Flow::consume($session, Provider::Google, $flow->state, T0 + 1))->toBeNull()
        ->and(Flow::consume($session, Provider::Discord, $flow->state, T0 + 2))->toBeNull();
});

test('FR-O3 a new flow overwrites the old one', function (): void {
    $session = memorySession();
    $old = Flow::start($session, Provider::Discord, T0);
    $new = Flow::start($session, Provider::Discord, T0 + 1);

    expect(Flow::consume($session, Provider::Discord, $old->state, T0 + 2))->toBeNull();

    // consume burned the stored (new) flow too, which is the safe direction: start again.
    $again = Flow::start($session, Provider::Discord, T0 + 3);
    expect($again->state)->not->toBe($new->state)
        ->and(Flow::consume($session, Provider::Discord, $again->state, T0 + 4))->not->toBeNull();
});

test('corrupt session data fails closed', function (mixed $garbage): void {
    $session = memorySession();
    $session->put('oauth-login.flow', $garbage);

    expect(Flow::consume($session, Provider::Discord, 'x', T0))->toBeNull()
        ->and($session->has('oauth-login.flow'))->toBeFalse();
})->with([
    'string' => ['nope'],
    'empty array' => [[[]]],
    'wrong types' => [[['provider' => 5, 'state' => [], 'verifier' => 1, 'at' => 'later']]],
    'unknown provider' => [[['provider' => 'gitlab', 'state' => 'x', 'verifier' => null, 'at' => T0]]],
]);

describe('AuthUrl', function (): void {
    test('AC-O1 Discord URL carries code flow parameters and no PKCE', function (): void {
        $flow = new Flow(Provider::Discord, 'STATE123', null, T0);
        $url = AuthUrl::build(Provider::Discord, 'cid', 'https://panel.test/extensions/oauth-login/callback/discord', $flow);

        expect($url)->toStartWith('https://discord.com/oauth2/authorize?');
        parse_str((string) parse_url($url, PHP_URL_QUERY), $query);
        expect($query)->toBe([
            'response_type' => 'code',
            'client_id' => 'cid',
            'redirect_uri' => 'https://panel.test/extensions/oauth-login/callback/discord',
            'scope' => 'identify email',
            'state' => 'STATE123',
        ]);
    });

    test('AC-O2 GitHub and Google URLs add the S256 challenge', function (Provider $provider): void {
        $flow = new Flow($provider, 'S', 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk', T0);
        $url = AuthUrl::build($provider, 'cid', 'https://panel.test/cb', $flow);

        parse_str((string) parse_url($url, PHP_URL_QUERY), $query);
        expect($url)->toStartWith($provider->authorizeUrl().'?')
            ->and($query['code_challenge'])->toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM')
            ->and($query['code_challenge_method'])->toBe('S256')
            ->and($query['scope'])->toBe($provider->scopes());
    })->with([Provider::Github, Provider::Google]);

    test('values are encoded, so a hostile client id cannot add parameters', function (): void {
        $flow = new Flow(Provider::Discord, 'S', null, T0);
        $url = AuthUrl::build(Provider::Discord, 'a&redirect_uri=https://evil.example', 'https://panel.test/cb', $flow);

        parse_str((string) parse_url($url, PHP_URL_QUERY), $query);
        expect($query['client_id'])->toBe('a&redirect_uri=https://evil.example')
            ->and($query['redirect_uri'])->toBe('https://panel.test/cb')
            ->and(substr_count($url, 'redirect_uri='))->toBe(1);
    });

    test('a client secret never appears in the URL', function (): void {
        $flow = new Flow(Provider::Github, 'S', 'v', T0);
        expect(AuthUrl::build(Provider::Github, 'cid', 'https://panel.test/cb', $flow))->not->toContain('secret');
    });
});

describe('link mode: a flow remembers who started it', function (): void {
    test('a login flow has no user, a link flow carries the user that started it', function (): void {
        $session = memorySession();
        expect(Flow::start($session, Provider::Discord, T0)->userId)->toBeNull();

        $flow = Flow::start($session, Provider::Discord, T0, 42);
        $consumed = Flow::consume($session, Provider::Discord, $flow->state, T0 + 1);

        expect($flow->userId)->toBe(42)->and($consumed->userId)->toBe(42);
    });

    test('a login flow comes back without a user', function (): void {
        $session = memorySession();
        $flow = Flow::start($session, Provider::Github, T0);

        expect(Flow::consume($session, Provider::Github, $flow->state, T0 + 1)->userId)->toBeNull();
    });

    test('a stored user id of the wrong type fails closed', function (mixed $uid): void {
        $session = memorySession();
        $flow = Flow::start($session, Provider::Discord, T0);
        $data = $session->get('oauth-login.flow');
        $session->put('oauth-login.flow', [...$data, 'uid' => $uid]);

        expect(Flow::consume($session, Provider::Discord, $flow->state, T0 + 1))->toBeNull();
    })->with(['7', 7.5, true, [[1]]]);

    test('a flow stored before link mode existed (no uid) is still a plain login flow', function (): void {
        $session = memorySession();
        $flow = Flow::start($session, Provider::Discord, T0);
        $data = $session->get('oauth-login.flow');
        unset($data['uid']);
        $session->put('oauth-login.flow', $data);

        expect(Flow::consume($session, Provider::Discord, $flow->state, T0 + 1)?->userId)->toBeNull();
    });
});
