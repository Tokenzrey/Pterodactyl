<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

final readonly class ModpackResult
{
    /** @param list<ModpackFile> $latestFiles */
    public function __construct(
        public ModpackSource $source,
        public string $projectId,
        public string $name,
        public string $summary,
        public int $downloads,
        public ?string $iconUrl,
        public array $latestFiles,
    ) {}
}
