<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

enum ModpackSource: string
{
    case CurseForge = 'curseforge';
    case Modrinth = 'modrinth';

    /**
     * A constant in the code, never a setting, so that nobody can point the Panel at an internal host (NFR-MI3).
     * Modrinth is v2: v1 is retired and answers 410.
     */
    public function baseUrl(): string
    {
        return match ($this) {
            self::CurseForge => 'https://api.curseforge.com/v1/',
            self::Modrinth => 'https://api.modrinth.com/v2/',
        };
    }

    public function requiresApiKey(): bool
    {
        return match ($this) {
            self::CurseForge => true,
            self::Modrinth => false,
        };
    }

    /**
     * Whether the source publishes server packs at all. CurseForge marks a file as one (`isServerPack`) and links a
     * client file to its server pack (`serverPackFileId`). Modrinth has no such thing: a modpack there is a client
     * format (.mrpack), so nothing from Modrinth can be installed as a server pack.
     */
    public function hasServerPacks(): bool
    {
        return match ($this) {
            self::CurseForge => true,
            self::Modrinth => false,
        };
    }

    /** The shape of a project or file id at this source. Ids go into a URL path, so they are checked before use. */
    public function idPattern(): string
    {
        return match ($this) {
            self::CurseForge => '/\A[0-9]{1,10}\z/',
            self::Modrinth => '/\A[A-Za-z0-9]{8}\z/',
        };
    }
}
