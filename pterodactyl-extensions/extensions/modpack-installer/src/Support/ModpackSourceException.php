<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

use RuntimeException;

/** A source (CurseForge or Modrinth) that could not answer a search or a lookup. Nothing it said is kept. */
final class ModpackSourceException extends RuntimeException
{
    public static function unavailable(): self
    {
        return new self('The modpack source is unavailable.');
    }

    public function errorCode(): string
    {
        return 'source_unavailable';
    }
}
