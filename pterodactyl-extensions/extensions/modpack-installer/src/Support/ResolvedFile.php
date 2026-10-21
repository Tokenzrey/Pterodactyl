<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

/** A file as the source describes it when asked for it by id: what the controller checks and the job downloads. */
final readonly class ResolvedFile
{
    public function __construct(
        public string $fileId,
        public string $name,
        public bool $isServerPack,
        /** Null when the author does not allow distribution outside CurseForge. */
        public ?string $downloadUrl,
        public ?int $sizeBytes,
        /** Lower-case hex SHA-1, when the source gives one. */
        public ?string $sha1,
    ) {}
}
