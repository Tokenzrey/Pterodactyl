<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

/** One page of search results, and how many there are in all (as far as the source will count them). */
final readonly class ModpackPage
{
    /** @param list<ModpackResult> $results */
    public function __construct(
        public array $results,
        public int $total,
    ) {}
}
