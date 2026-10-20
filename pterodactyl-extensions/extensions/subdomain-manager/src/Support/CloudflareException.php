<?php

declare(strict_types=1);

namespace SubdomainManager\Support;

use RuntimeException;

/**
 * A Cloudflare call that did not give a usable answer. `safe` is the only text meant for people
 * (logs, the admin form): the first Cloudflare error as "code: message", cleaned, cut to 200
 * characters and with the token removed. No previous exception is chained, since transport errors can
 * echo request details.
 */
final class CloudflareException extends RuntimeException
{
    public function __construct(
        public readonly bool $retryable,
        public readonly string $safe,
        public readonly ?int $status = null,
    ) {
        parent::__construct($safe);
    }
}
