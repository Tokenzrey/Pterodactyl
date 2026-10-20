<?php

declare(strict_types=1);

namespace OauthLogin\Support;

/**
 * The three supported identity providers. Every endpoint is a constant here, never a setting,
 * so an administrator (or an attacker with settings access) cannot point the flow elsewhere.
 */
enum Provider: string
{
    case Discord = 'discord';
    case Github = 'github';
    case Google = 'google';

    public function label(): string
    {
        return match ($this) {
            self::Discord => 'Discord',
            self::Github => 'GitHub',
            self::Google => 'Google',
        };
    }

    public function authorizeUrl(): string
    {
        return match ($this) {
            self::Discord => 'https://discord.com/oauth2/authorize',
            self::Github => 'https://github.com/login/oauth/authorize',
            self::Google => 'https://accounts.google.com/o/oauth2/v2/auth',
        };
    }

    public function tokenUrl(): string
    {
        return match ($this) {
            self::Discord => 'https://discord.com/api/oauth2/token',
            self::Github => 'https://github.com/login/oauth/access_token',
            self::Google => 'https://oauth2.googleapis.com/token',
        };
    }

    public function profileUrl(): string
    {
        return match ($this) {
            self::Discord => 'https://discord.com/api/users/@me',
            self::Github => 'https://api.github.com/user',
            self::Google => 'https://openidconnect.googleapis.com/v1/userinfo',
        };
    }

    /** GitHub keeps verified addresses on a separate endpoint; the others return them in the profile. */
    public function emailsUrl(): ?string
    {
        return $this === self::Github ? 'https://api.github.com/user/emails' : null;
    }

    public function scopes(): string
    {
        return match ($this) {
            self::Discord => 'identify email',
            self::Github => 'read:user user:email',
            self::Google => 'openid email profile',
        };
    }

    /** Discord does not document PKCE; GitHub and Google do. */
    public function usesPkce(): bool
    {
        return $this !== self::Discord;
    }

    /** Value the callback's `iss` parameter must have when the provider sends one (RFC 9207). */
    public function issuer(): ?string
    {
        return $this === self::Discord ? 'https://discord.com' : null;
    }
}
