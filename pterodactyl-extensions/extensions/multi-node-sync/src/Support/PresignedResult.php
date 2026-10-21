<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

final readonly class PresignedResult
{
    public function __construct(
        public string $url,
        public string $method,
        public string $expiresAt,
        public string $objectKey,
    ) {}
}
