<?php

declare(strict_types=1);

namespace OauthLogin\Support;

use Illuminate\Contracts\Session\Session;

/**
 * One in-flight authorisation: the `state` that ties the callback to this browser session and,
 * for providers that support it, the PKCE verifier. It lives only in the session, is replaced by
 * every new start and is removed by every consume, whatever the outcome.
 */
final readonly class Flow
{
    public const TTL = 600;

    private const KEY = 'oauth-login.flow';

    public function __construct(
        public Provider $provider,
        public string $state,
        public ?string $verifier,
        public int $startedAt,
        /** The signed-in user who started a "connect this account" flow; null for a sign-in flow. */
        public ?int $userId = null,
    ) {}

    public static function start(Session $session, Provider $provider, int $now, ?int $userId = null): self
    {
        $flow = new self($provider, self::random(), $provider->usesPkce() ? self::random() : null, $now, $userId);
        $session->put(self::KEY, [
            'provider' => $provider->value,
            'state' => $flow->state,
            'verifier' => $flow->verifier,
            'at' => $now,
            'uid' => $userId,
        ]);

        return $flow;
    }

    /**
     * Takes the flow out of the session first, so a state can never be used twice, then checks it.
     * Returns null when there is none, it belongs to another provider, it is older than TTL
     * or the state differs.
     */
    public static function consume(Session $session, Provider $provider, string $state, int $now): ?self
    {
        $data = $session->pull(self::KEY);
        if (! is_array($data)
            || ! is_string($data['provider'] ?? null) || ! is_string($data['state'] ?? null)
            || ! is_int($data['at'] ?? null) || ! (is_int($data['uid'] ?? null) || ($data['uid'] ?? null) === null) || ! (is_string($data['verifier'] ?? null) || ($data['verifier'] ?? null) === null)
            || Provider::tryFrom($data['provider']) !== $provider
        ) {
            return null;
        }

        if ($now - $data['at'] > self::TTL || ! hash_equals($data['state'], $state)) {
            return null;
        }

        return new self($provider, $data['state'], $data['verifier'], $data['at'], $data['uid'] ?? null);
    }

    /** PKCE S256 challenge, or null when this provider does not use PKCE. */
    public function challenge(): ?string
    {
        return $this->verifier === null ? null : self::base64Url(hash('sha256', $this->verifier, true));
    }

    /** 256 bits, url-safe: satisfies the 128-bit state minimum and the 43-128 character PKCE verifier. */
    private static function random(): string
    {
        return self::base64Url(random_bytes(32));
    }

    private static function base64Url(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }
}
