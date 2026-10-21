<?php

declare(strict_types=1);

namespace FileTransfer\Support;

use RuntimeException;

/**
 * A transfer that failed for a reason the user can be told about. `reason` is one of the fixed codes of FR-FT19
 * (invalid_url, download_failed, download_too_large, upload_failed, timeout, connection_refused, ...) and is all that
 * is ever shown or logged: not the remote server's answer, not the URL. `retryable` says whether trying again can help.
 */
final class TransferException extends RuntimeException
{
    public function __construct(public readonly string $reason, public readonly bool $retryable = false)
    {
        parent::__construct($reason);
    }
}
