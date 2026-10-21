<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

use RuntimeException;

/**
 * A failed call to a node's file API. The message is a fixed reason code, never what Wings said.
 * $unreachable is true when no answer came at all: the node is down or refused the connection.
 */
final class WingsException extends RuntimeException
{
    public function __construct(string $reason, public readonly bool $unreachable = false)
    {
        parent::__construct($reason);
    }
}
