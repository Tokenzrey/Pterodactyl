<?php

declare(strict_types=1);

namespace PlayerManager\Support;

use RuntimeException;

/**
 * A failed RCON exchange. The code is one of the fixed values below and is the only part an API response may show.
 * The detail is internal (logs and tests); it never carries the password or raw server output.
 */
final class RconException extends RuntimeException
{
    public const NOT_CONFIGURED = 'rcon_not_configured';

    public const CONNECTION_FAILED = 'rcon_connection_failed';

    public const AUTH_FAILED = 'rcon_auth_failed';

    public const TIMEOUT = 'rcon_timeout';

    public const ERROR = 'rcon_error';

    public function __construct(public readonly string $reason, string $detail = '')
    {
        parent::__construct($detail === '' ? $reason : "{$reason}: {$detail}");
    }
}
