<?php

declare(strict_types=1);

namespace OauthLogin\Support;

use Pterodactyl\Models\User;

/** Outcome of matching a provider profile to a Panel user: either a user to sign in, or an error code. */
final readonly class Resolution
{
    private function __construct(
        public ?User $user,
        public ?string $error,
        public bool $linked,
        public bool $created,
    ) {}

    public static function user(User $user, bool $linked = false, bool $created = false): self
    {
        return new self($user, null, $linked, $created);
    }

    public static function failed(string $error): self
    {
        return new self(null, $error, false, false);
    }
}
