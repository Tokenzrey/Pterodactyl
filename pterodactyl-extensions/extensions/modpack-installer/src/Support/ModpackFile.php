<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

/**
 * A file a search result offers. For CurseForge, `fileId` of a server pack is the id of the server pack itself, which
 * is a different file from the client pack it was found under. No download address is carried: the browser never sees
 * one, because the job asks the source for it when it installs (T-MI8).
 */
final readonly class ModpackFile
{
    public function __construct(
        public string $fileId,
        public string $name,
        public ?string $gameVersion,
        public ?string $loader,
        public bool $isServerPack,
        public ?float $fileSizeMb,
    ) {}
}
