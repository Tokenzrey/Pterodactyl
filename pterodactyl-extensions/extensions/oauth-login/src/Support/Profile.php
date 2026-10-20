<?php

declare(strict_types=1);

namespace OauthLogin\Support;

/** What the Panel needs to know about a provider account. The email is lower-case and provider-verified. */
final readonly class Profile
{
    public function __construct(
        public string $providerUserId,
        public string $email,
        public string $usernameHint,
        public string $displayName,
    ) {}
}
