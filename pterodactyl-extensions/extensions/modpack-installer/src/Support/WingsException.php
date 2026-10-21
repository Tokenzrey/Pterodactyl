<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

use RuntimeException;

/**
 * A failed call to a server's node. The message is a fixed reason, never what Wings said. $unreachable is true when
 * no answer came at all, which is the only kind of failure worth trying again.
 */
final class WingsException extends RuntimeException
{
    public function __construct(string $reason, public readonly bool $unreachable = false)
    {
        parent::__construct($reason);
    }
}
