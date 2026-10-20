<?php

declare(strict_types=1);

namespace OauthLogin\Support;

use RuntimeException;

/**
 * A provider exchange that did not give us a trustworthy profile. `reason` is one of the fixed
 * error codes the login page understands; the message is a fixed, secret-free description meant
 * for logs (never a response body, URL, code or token). No previous exception is chained, because
 * transport errors can echo request details.
 */
final class ProviderException extends RuntimeException
{
    public const FAILED = Errors::PROVIDER_ERROR;

    public const UNVERIFIED = Errors::EMAIL_UNVERIFIED;

    private function __construct(public readonly string $reason, string $detail)
    {
        parent::__construct($detail);
    }

    public static function failed(string $detail): self
    {
        return new self(self::FAILED, $detail);
    }

    public static function unverified(): self
    {
        return new self(self::UNVERIFIED, 'the provider returned no verified email address');
    }
}
