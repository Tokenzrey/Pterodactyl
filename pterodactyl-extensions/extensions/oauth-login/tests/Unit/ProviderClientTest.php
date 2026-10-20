<?php

declare(strict_types=1);

use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\Request;
use OauthLogin\Support\Profile;
use OauthLogin\Support\Provider;
use OauthLogin\Support\ProviderClient;
use OauthLogin\Support\ProviderException;
use Psr\Http\Message\RequestInterface;

// FR-O6, FR-O7, AC-O15, NFR-O3, NFR-O5, NFR-O6. No real network: a standalone HTTP factory
// with stray requests prevented, response bodies shaped like the providers' documentation.

const PC_CID = 'client-id-1';
const PC_SECRET = 'S3CRET-VALUE-do-not-leak';
const PC_CODE = 'AUTH-CODE-123';
const PC_VERIFIER = 'VERIFIER-abcdefghijklmnopqrstuvwxyz0123456789ABC';
const PC_REDIRECT = 'https://panel.test/extensions/oauth-login/callback/x';
const PC_TOKEN = 'ACCESS-TOKEN-do-not-leak';

/**
 * @param  array<string, mixed>  $routes
 * @param  array<int, array<string, mixed>>  $options  filled with the Guzzle options of every request
 */
function pcHttp(array $routes, array &$options = []): Factory
{
    $http = new Factory;
    $http->preventStrayRequests();
    // A plain closure: an arrow function would capture $options by value and lose the recording.
    $http->globalMiddleware(function (callable $handler) use (&$options): Closure {
        return function (RequestInterface $request, array $opts) use ($handler, &$options) {
            $options[] = $opts;

            return $handler($request, $opts);
        };
    });
    $http->fake($routes);

    return $http;
}

function pcFetch(Factory $http, Provider $provider): Profile
{
    return (new ProviderClient($http))->fetchProfile($provider, PC_CID, PC_SECRET, PC_CODE, PC_REDIRECT, $provider->usesPkce() ? PC_VERIFIER : null);
}

function pcFailure(Factory $http, Provider $provider): ?ProviderException
{
    try {
        pcFetch($http, $provider);
    } catch (ProviderException $e) {
        return $e;
    }

    return null;
}

/** @return array<string, mixed> */
function pcRoutes(Provider $provider, array $override = []): array
{
    $routes = match ($provider) {
        Provider::Discord => [
            'https://discord.com/api/oauth2/token' => Factory::response(['access_token' => PC_TOKEN, 'token_type' => 'Bearer', 'expires_in' => 604800, 'scope' => 'identify email']),
            'https://discord.com/api/users/@me' => Factory::response(['id' => '80351110224678912', 'username' => 'nelly', 'global_name' => 'Nelly', 'verified' => true, 'email' => 'Nelly@Discord.com']),
        ],
        Provider::Github => [
            'https://github.com/login/oauth/access_token' => Factory::response(['access_token' => PC_TOKEN, 'scope' => 'read:user,user:email', 'token_type' => 'bearer']),
            'https://api.github.com/user' => Factory::response(['login' => 'octocat', 'id' => 1, 'name' => 'monalisa octocat']),
            'https://api.github.com/user/emails' => Factory::response([['email' => 'octocat@github.com', 'verified' => true, 'primary' => true, 'visibility' => 'public']]),
        ],
        Provider::Google => [
            'https://oauth2.googleapis.com/token' => Factory::response(['access_token' => PC_TOKEN, 'expires_in' => 3599, 'token_type' => 'Bearer', 'id_token' => 'x.y.z']),
            'https://openidconnect.googleapis.com/v1/userinfo' => Factory::response(['sub' => '110248495921238986420', 'name' => 'Ada', 'email' => 'ada@example.com', 'email_verified' => true]),
        ],
    };

    return $override + $routes;
}

/** @return list<Request> */
function pcSent(Factory $http): array
{
    return array_map(fn (array $pair): Request => $pair[0], $http->recorded()->all());
}

test('AC-O8 Discord: token exchange, then profile, in that order', function (): void {
    $http = pcHttp(pcRoutes(Provider::Discord));

    expect(pcFetch($http, Provider::Discord))->toEqual(new Profile('80351110224678912', 'nelly@discord.com', 'nelly', 'Nelly'));

    [$token, $me] = pcSent($http);
    expect(pcSent($http))->toHaveCount(2)
        ->and($token->method())->toBe('POST')
        ->and($token->url())->toBe('https://discord.com/api/oauth2/token')
        ->and($token->isForm())->toBeTrue()
        ->and($token->data())->toBe([
            'grant_type' => 'authorization_code',
            'code' => PC_CODE,
            'redirect_uri' => PC_REDIRECT,
            'client_id' => PC_CID,
            'client_secret' => PC_SECRET,
        ])
        ->and($me->method())->toBe('GET')
        ->and($me->url())->toBe('https://discord.com/api/users/@me')
        ->and($me->header('Authorization'))->toBe(['Bearer '.PC_TOKEN]);
});

test('FR-O6 GitHub: token exchange with verifier, profile and emails with the GitHub media type', function (): void {
    $http = pcHttp(pcRoutes(Provider::Github));

    expect(pcFetch($http, Provider::Github))->toEqual(new Profile('1', 'octocat@github.com', 'octocat', 'monalisa octocat'));

    [$token, $user, $emails] = pcSent($http);
    expect(pcSent($http))->toHaveCount(3)
        ->and($token->url())->toBe('https://github.com/login/oauth/access_token')
        ->and($token->data()['code_verifier'])->toBe(PC_VERIFIER)
        ->and($token->header('Accept'))->toBe(['application/json'])
        ->and($user->url())->toBe('https://api.github.com/user')
        ->and($emails->url())->toBe('https://api.github.com/user/emails');

    foreach ([$user, $emails] as $request) {
        expect($request->header('Authorization'))->toBe(['Bearer '.PC_TOKEN])
            ->and($request->header('Accept'))->toBe(['application/vnd.github+json'])
            ->and($request->header('User-Agent')[0] ?? '')->not->toBe('');
    }
});

test('FR-O6 Google: token exchange with verifier, then userinfo', function (): void {
    $http = pcHttp(pcRoutes(Provider::Google));

    expect(pcFetch($http, Provider::Google))->toEqual(new Profile('110248495921238986420', 'ada@example.com', 'ada', 'Ada'));

    [$token, $info] = pcSent($http);
    expect(pcSent($http))->toHaveCount(2)
        ->and($token->url())->toBe('https://oauth2.googleapis.com/token')
        ->and($token->data()['code_verifier'])->toBe(PC_VERIFIER)
        ->and($info->url())->toBe('https://openidconnect.googleapis.com/v1/userinfo');
});

test('Discord sends no code_verifier', function (): void {
    $http = pcHttp(pcRoutes(Provider::Discord));
    pcFetch($http, Provider::Discord);

    expect(pcSent($http)[0]->data())->not->toHaveKey('code_verifier');
});

test('NFR-O5 every request has a 10 second timeout, never follows redirects and keeps TLS verification', function (Provider $provider): void {
    $options = [];
    pcFetch(pcHttp(pcRoutes($provider), $options), $provider);

    expect($options)->not->toBeEmpty();
    foreach ($options as $opts) {
        expect($opts['allow_redirects'])->toBeFalse()
            ->and($opts['timeout'])->toBe(10)
            ->and($opts['verify'] ?? true)->not->toBeFalse();
    }
})->with(Provider::cases());

test('NFR-O3 the secret, code, verifier and token never travel in a URL', function (Provider $provider): void {
    $http = pcHttp(pcRoutes($provider));
    pcFetch($http, $provider);

    foreach (pcSent($http) as $request) {
        expect(parse_url($request->url(), PHP_URL_QUERY))->toBeNull();
        foreach ([PC_SECRET, PC_CODE, PC_VERIFIER, PC_TOKEN] as $value) {
            expect($request->url())->not->toContain($value);
        }
    }
})->with(Provider::cases());

describe('failures are provider_error, stop the flow early and leak nothing', function (): void {
    $tokenBodies = [
        'HTTP 400' => Factory::response(['error' => 'invalid_grant'], 400),
        'HTTP 401' => Factory::response(['error' => 'invalid_client'], 401),
        'HTTP 500' => Factory::response('boom', 500),
        'redirect' => Factory::response('', 302, ['Location' => 'https://evil.example/']),
        'invalid JSON' => Factory::response('this is not json', 200),
        'JSON list' => Factory::response([], 200),
        'JSON string' => Factory::response('"just a string"', 200, ['Content-Type' => 'application/json']),
        'error with HTTP 200 (GitHub style)' => Factory::response(['error' => 'bad_verification_code', 'error_description' => 'The code passed is incorrect or expired.'], 200),
        'empty token' => Factory::response(['access_token' => ''], 200),
        'non-string token' => Factory::response(['access_token' => 12345], 200),
        'connection failure' => Factory::failedConnection('cURL error 28: timed out'),
    ];

    test('AC-O15 token endpoint', function (string $label, mixed $response): void {
        $http = pcHttp(pcRoutes(Provider::Github, ['https://github.com/login/oauth/access_token' => $response]));
        $e = pcFailure($http, Provider::Github);

        expect($e)->toBeInstanceOf(ProviderException::class)
            ->and($e->reason)->toBe(ProviderException::FAILED)
            ->and(pcSent($http))->toHaveCount(1); // only the token request: the profile endpoints are never reached
        foreach ([PC_SECRET, PC_CODE, PC_VERIFIER, PC_TOKEN] as $value) {
            expect($e->getMessage())->not->toContain($value);
        }
    })->with(array_map(fn ($r, $k) => [$k, $r], $tokenBodies, array_keys($tokenBodies)));

    $profileBodies = [
        'HTTP 401' => Factory::response(['message' => 'Bad credentials'], 401),
        'HTTP 403' => Factory::response(['message' => 'forbidden'], 403),
        'HTTP 500' => Factory::response('boom', 500),
        'redirect' => Factory::response('', 302, ['Location' => 'https://evil.example/']),
        'invalid JSON' => Factory::response('<html>', 200),
        'connection failure' => Factory::failedConnection('timed out'),
    ];

    test('AC-O15 profile endpoint', function (Provider $provider, string $label, mixed $response): void {
        $profileUrl = $provider->profileUrl();
        $http = pcHttp(pcRoutes($provider, [$profileUrl => $response]));
        $e = pcFailure($http, $provider);

        expect($e)->toBeInstanceOf(ProviderException::class)->and($e->reason)->toBe(ProviderException::FAILED);
        foreach ([PC_SECRET, PC_CODE, PC_VERIFIER, PC_TOKEN] as $value) {
            expect($e->getMessage())->not->toContain($value);
        }
    })->with(function () use ($profileBodies) {
        foreach (Provider::cases() as $provider) {
            foreach ($profileBodies as $label => $response) {
                yield $provider->value.': '.$label => [$provider, $label, $response];
            }
        }
    });

    test('GitHub emails endpoint failing (for example missing user:email scope) is provider_error', function (string $label, mixed $response): void {
        $http = pcHttp(pcRoutes(Provider::Github, ['https://api.github.com/user/emails' => $response]));

        expect(pcFailure($http, Provider::Github)?->reason)->toBe(ProviderException::FAILED);
    })->with([
        'HTTP 403' => ['403', Factory::response(['message' => 'Resource not accessible'], 403)],
        'invalid JSON' => ['json', Factory::response('nope', 200)],
        'HTTP 500' => ['500', Factory::response('', 500)],
    ]);
});

describe('an account the provider has not verified is email_unverified, not an outage', function (): void {
    test('AC-O10 Discord', function (): void {
        $http = pcHttp(pcRoutes(Provider::Discord, ['https://discord.com/api/users/@me' => Factory::response(['id' => '1', 'username' => 'n', 'verified' => false, 'email' => 'n@example.com'])]));
        expect(pcFailure($http, Provider::Discord)?->reason)->toBe(ProviderException::UNVERIFIED);
    });

    test('AC-O10 / EC-O6 GitHub without a verified primary address', function (): void {
        $http = pcHttp(pcRoutes(Provider::Github, ['https://api.github.com/user/emails' => Factory::response([['email' => 'a@example.com', 'verified' => true, 'primary' => false]])]));
        expect(pcFailure($http, Provider::Github)?->reason)->toBe(ProviderException::UNVERIFIED);
    });

    test('AC-O10 Google', function (): void {
        $http = pcHttp(pcRoutes(Provider::Google, ['https://openidconnect.googleapis.com/v1/userinfo' => Factory::response(['sub' => '1', 'email' => 'a@example.com', 'email_verified' => false])]));
        expect(pcFailure($http, Provider::Google)?->reason)->toBe(ProviderException::UNVERIFIED);
    });
});

test('NFR-O6 a request to anything but the fixed endpoints is not possible: unfaked URLs are refused', function (): void {
    $http = pcHttp([]);

    expect(fn () => pcFetch($http, Provider::Discord))->toThrow(RuntimeException::class);
});
