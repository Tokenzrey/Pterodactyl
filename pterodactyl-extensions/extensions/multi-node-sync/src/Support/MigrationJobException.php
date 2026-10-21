<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

use RuntimeException;

/**
 * Why a migration failed, as one of a fixed set of codes. The Panel's transfer does the moving; the job only reports.
 */
final class MigrationJobException extends RuntimeException
{
    public const SOURCE_UNAVAILABLE = 'source_unavailable';

    public const TARGET_UNAVAILABLE = 'target_unavailable';

    public const NO_ADMIN = 'no_admin';

    private function __construct(private readonly string $errorCode, string $message)
    {
        parent::__construct($message);
    }

    /** The server to move no longer exists. */
    public static function sourceUnavailable(): self
    {
        return new self(self::SOURCE_UNAVAILABLE, 'The server to migrate no longer exists.');
    }

    /** The Panel refused the transfer, could not start it, or it failed or did not finish in time. */
    public static function targetUnavailable(): self
    {
        return new self(self::TARGET_UNAVAILABLE, 'The Panel could not transfer the server to the target node.');
    }

    /** The Panel only transfers on behalf of a root administrator, and there is none to act for. */
    public static function noAdmin(): self
    {
        return new self(self::NO_ADMIN, 'There is no root administrator to run the transfer as.');
    }

    public function errorCode(): string
    {
        return $this->errorCode;
    }
}
