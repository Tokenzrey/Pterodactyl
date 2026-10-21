<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

use RuntimeException;

/**
 * Why an installation failed, as one of the fixed codes of FR-MI18. The message is ours; what the source or Wings said
 * is never passed on. $retryable is true for a failure that may not happen again (a node that did not answer, a source
 * that was busy), false for one that will (a pack that is too big, a file that is gone).
 */
final class ModpackJobException extends RuntimeException
{
    public const SOURCE_UNAVAILABLE = 'source_unavailable';

    public const FILE_NOT_FOUND = 'file_not_found';

    public const NOT_SERVER_PACK = 'not_server_pack';

    public const DOWNLOAD_FAILED = 'download_failed';

    public const DOWNLOAD_TOO_LARGE = 'download_too_large';

    public const UPLOAD_FAILED = 'upload_failed';

    public const EXTRACT_FAILED = 'extract_failed';

    public const SANITIZE_FAILED = 'sanitize_failed';

    public const DISK_FULL = 'disk_full';

    /** Every code a record can carry (FR-MI18). */
    public const CODES = [
        self::SOURCE_UNAVAILABLE,
        self::FILE_NOT_FOUND,
        self::NOT_SERVER_PACK,
        self::DOWNLOAD_FAILED,
        self::DOWNLOAD_TOO_LARGE,
        self::UPLOAD_FAILED,
        self::EXTRACT_FAILED,
        self::SANITIZE_FAILED,
        self::DISK_FULL,
    ];

    private function __construct(private readonly string $errorCode, string $message, public readonly bool $retryable = false)
    {
        parent::__construct($message);
    }

    public function errorCode(): string
    {
        return $this->errorCode;
    }

    public static function sourceUnavailable(): self
    {
        return new self(self::SOURCE_UNAVAILABLE, 'The modpack source is unavailable.', true);
    }

    public static function fileNotFound(): self
    {
        return new self(self::FILE_NOT_FOUND, 'The file does not exist at the source.');
    }

    public static function notServerPack(): self
    {
        return new self(self::NOT_SERVER_PACK, 'The file is not a server pack.');
    }

    public static function downloadFailed(bool $retryable = false): self
    {
        return new self(self::DOWNLOAD_FAILED, 'The download failed.', $retryable);
    }

    public static function downloadTooLarge(): self
    {
        return new self(self::DOWNLOAD_TOO_LARGE, 'The modpack exceeds the maximum download size.');
    }

    public static function uploadFailed(bool $retryable = false): self
    {
        return new self(self::UPLOAD_FAILED, 'The upload to the server failed.', $retryable);
    }

    public static function extractFailed(): self
    {
        return new self(self::EXTRACT_FAILED, 'The archive could not be extracted.');
    }

    public static function sanitizeFailed(): self
    {
        return new self(self::SANITIZE_FAILED, 'The conflicting files could not be removed.');
    }

    public static function diskFull(): self
    {
        return new self(self::DISK_FULL, 'The Panel has no room for the download.');
    }
}
