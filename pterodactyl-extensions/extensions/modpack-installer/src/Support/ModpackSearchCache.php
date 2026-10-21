<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

final class ModpackSearchCache
{
    /**
     * One key per source, query, filters and page (FR-MI3). The query is user text, so it is hashed rather than used as
     * it is: a cache key must not carry spaces, newlines or whatever else a person can type.
     */
    public static function key(ModpackSource $source, string $query, ?string $gameVersion, ?string $loader, int $page): string
    {
        return 'modpack-installer:search:'.hash('sha256', json_encode([$source->value, $query, $gameVersion, $loader, $page], JSON_THROW_ON_ERROR));
    }
}
