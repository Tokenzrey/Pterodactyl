<?php

declare(strict_types=1);

namespace OauthLogin\Support;

use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Validation\ValidationException;
use OauthLogin\Models\Identity;
use Pterodactyl\Contracts\Users\CreatesUsers;
use Pterodactyl\Models\User;

/**
 * Decides which Panel user a verified provider profile belongs to (FR-O8 to FR-O11):
 * a linked identity first, then a user with the same verified email, then a new user when
 * registration is on. The sign-in policy is checked before any link or account is created.
 */
final readonly class AccountResolver
{
    public function __construct(private CreatesUsers $users) {}

    public function resolve(Provider $provider, Profile $profile, OauthSettings $settings): Resolution
    {
        // Two tries: a parallel callback may create the same user or link between our lookup and
        // our write (EC-O4). The second pass then finds what the first one lost to.
        for ($try = 1; $try <= 2; $try++) {
            if (($resolution = $this->attempt($provider, $profile, $settings)) !== null) {
                return $resolution;
            }
        }

        return Resolution::failed(Errors::REGISTRATION_FAILED);
    }

    /**
     * Connect a provider account to a user who is already signed in (their choice, so the email need not match).
     * One provider account belongs to one user, and a user holds one account per provider (FR-O10).
     * `linked` on the result is false when the connection already existed.
     */
    public function attach(User $user, Provider $provider, Profile $profile): Resolution
    {
        for ($try = 1; $try <= 2; $try++) {
            $existing = Identity::query()->where('provider', $provider->value)->where('provider_user_id', $profile->providerUserId)->first();
            if ($existing !== null) {
                return $existing->user_id === $user->id ? Resolution::user($user) : Resolution::failed(Errors::IDENTITY_CONFLICT);
            }
            if (Identity::query()->where('user_id', $user->id)->where('provider', $provider->value)->exists()) {
                return Resolution::failed(Errors::IDENTITY_CONFLICT);
            }

            try {
                Identity::query()->create(['user_id' => $user->id, 'provider' => $provider->value, 'provider_user_id' => $profile->providerUserId]);

                return Resolution::user($user, linked: true);
            } catch (UniqueConstraintViolationException) {
                // A parallel request connected something first: look again.
            }
        }

        return Resolution::failed(Errors::IDENTITY_CONFLICT);
    }

    /** @return Resolution|null null when a concurrent request got there first and the caller should look again */
    private function attempt(Provider $provider, Profile $profile, OauthSettings $settings): ?Resolution
    {
        $identity = Identity::query()->where('provider', $provider->value)->where('provider_user_id', $profile->providerUserId)->first();
        if ($identity !== null) {
            return $this->admit($identity->user, $settings);
        }

        $user = User::query()->where('email', $profile->email)->first();
        if ($user !== null) {
            return $this->link($provider, $profile, $user, $settings);
        }

        return $settings->allowRegistration() ? $this->register($provider, $profile) : Resolution::failed(Errors::NO_ACCOUNT);
    }

    private function admit(User $user, OauthSettings $settings, bool $linked = false, bool $created = false): Resolution
    {
        $error = Policy::check((bool) $user->root_admin, (bool) $user->use_totp, $settings->allowAdminLogin(), $settings->twoFactorPolicy());

        return $error === null ? Resolution::user($user, $linked, $created) : Resolution::failed($error);
    }

    private function link(Provider $provider, Profile $profile, User $user, OauthSettings $settings): ?Resolution
    {
        // Policy first: a refused user must not gain a link (AC-O11).
        $refused = $this->admit($user, $settings);
        if ($refused->error !== null) {
            return $refused;
        }

        if (Identity::query()->where('user_id', $user->id)->where('provider', $provider->value)->exists()) {
            return Resolution::failed(Errors::IDENTITY_CONFLICT);
        }

        try {
            Identity::query()->create(['user_id' => $user->id, 'provider' => $provider->value, 'provider_user_id' => $profile->providerUserId]);
        } catch (UniqueConstraintViolationException) {
            return null;
        }

        return Resolution::user($user, linked: true);
    }

    private function register(Provider $provider, Profile $profile): ?Resolution
    {
        $username = Usernames::generate($profile->usernameHint, fn (string $candidate): bool => User::query()->where('username', $candidate)->exists());
        if ($username === null) {
            return Resolution::failed(Errors::REGISTRATION_FAILED);
        }

        [$first, $last] = array_pad(explode(' ', trim($profile->displayName), 2), 2, '');

        try {
            $user = $this->users->create([
                'email' => $profile->email,
                'username' => $username,
                'name_first' => mb_substr($first, 0, 191) ?: $username,
                'name_last' => mb_substr(trim($last), 0, 191) ?: '-',
                'root_admin' => false,
            ]);
        } catch (ValidationException) {
            // A parallel callback may have created this very user: look again. Otherwise the Panel
            // refused the address or name (EC-O3).
            return User::query()->where('email', $profile->email)->exists() ? null : Resolution::failed(Errors::REGISTRATION_FAILED);
        }

        try {
            Identity::query()->create(['user_id' => $user->id, 'provider' => $provider->value, 'provider_user_id' => $profile->providerUserId]);
        } catch (UniqueConstraintViolationException) {
            return null;
        }

        return Resolution::user($user, linked: true, created: true);
    }
}
