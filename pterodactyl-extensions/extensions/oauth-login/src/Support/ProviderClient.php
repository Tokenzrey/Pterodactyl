<?php

declare(strict_types=1);

namespace OauthLogin\Support;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\PendingRequest;
use Illuminate\Http\Client\Response;

/**
 * Exchanges an authorisation code for a verified Profile. Endpoints come from Provider (constants),
 * every request has a 10 second timeout, follows no redirects and verifies TLS. The access token
 * lives only in local variables: it is never stored, logged or put in a URL.
 */
final class ProviderClient
{
    private const TIMEOUT = 10;

    private const CONNECT_TIMEOUT = 5;

    private const USER_AGENT = 'pterodactyl-oauth-login';

    public function __construct(private readonly Factory $http) {}

    /**
     * @throws ProviderException FAILED for transport/HTTP/format problems, UNVERIFIED when the
     *                           provider gave no verified email
     */
    public function fetchProfile(Provider $provider, string $clientId, string $clientSecret, string $code, string $redirectUri, ?string $verifier): Profile
    {
        $token = $this->exchange($provider, $clientId, $clientSecret, $code, $redirectUri, $verifier);

        $profile = match ($provider) {
            Provider::Discord => ProfileParser::discord($this->getJson($provider, $provider->profileUrl(), $token)),
            Provider::Github => ProfileParser::github(
                $this->getJson($provider, $provider->profileUrl(), $token),
                $this->getJson($provider, (string) $provider->emailsUrl(), $token),
            ),
            Provider::Google => ProfileParser::google($this->getJson($provider, $provider->profileUrl(), $token)),
        };

        return $profile ?? throw ProviderException::unverified();
    }

    private function exchange(Provider $provider, string $clientId, string $clientSecret, string $code, string $redirectUri, ?string $verifier): string
    {
        $body = [
            'grant_type' => 'authorization_code',
            'code' => $code,
            'redirect_uri' => $redirectUri,
            'client_id' => $clientId,
            'client_secret' => $clientSecret,
        ];
        if ($verifier !== null) {
            $body['code_verifier'] = $verifier;
        }

        $data = $this->decode($provider, 'token', $this->send(fn () => $this->request('application/json')->asForm()->post($provider->tokenUrl(), $body)));
        $token = $data['access_token'] ?? null;

        // GitHub answers a bad code with HTTP 200 and an "error" field, so a missing token is a failure too.
        return is_string($token) && $token !== '' ? $token : throw ProviderException::failed($provider->value.' token response had no access_token');
    }

    /** @return array<mixed> */
    private function getJson(Provider $provider, string $url, string $token): array
    {
        $accept = $provider === Provider::Github ? 'application/vnd.github+json' : 'application/json';

        return $this->decode($provider, 'profile', $this->send(fn () => $this->request($accept)->withToken($token)->get($url)));
    }

    private function request(string $accept): PendingRequest
    {
        return $this->http->accept($accept)
            ->withUserAgent(self::USER_AGENT)
            ->connectTimeout(self::CONNECT_TIMEOUT)
            ->timeout(self::TIMEOUT)
            ->withoutRedirecting();
    }

    private function send(callable $call): Response
    {
        try {
            return $call();
        } catch (ConnectionException) {
            throw ProviderException::failed('connection to the provider failed or timed out');
        }
    }

    /** @return array<mixed> */
    private function decode(Provider $provider, string $stage, Response $response): array
    {
        if (! $response->successful()) {
            throw ProviderException::failed(sprintf('%s %s endpoint answered HTTP %d', $provider->value, $stage, $response->status()));
        }

        $data = $response->json();

        return is_array($data) ? $data : throw ProviderException::failed($provider->value.' '.$stage.' endpoint did not return JSON');
    }
}
