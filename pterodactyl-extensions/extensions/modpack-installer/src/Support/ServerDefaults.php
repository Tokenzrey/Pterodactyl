<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionSettingDefinition as Setting;
use Pterodactyl\Services\Extensions\ExtensionSettings;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;

/**
 * What a server's search opens with: its source, Minecraft version and loader (plan 12, "Pengaturan per-server").
 *
 * They are stored per server, and never as global settings, so the admin settings form does not show them. Nothing here
 * is read from or written to the global values.
 */
final class ServerDefaults
{
    public const SOURCE = 'default_source';

    public const GAME_VERSION = 'default_game_version';

    public const LOADER = 'default_loader';

    /**
     * The definitions, unscoped. Use for(), which scopes them to one server.
     */
    public static function definition(): ExtensionSettingsDefinition
    {
        return new ExtensionSettingsDefinition(new ExtensionSettings(ModpackSettings::ID), [
            Setting::make(self::SOURCE, self::SOURCE, ModpackSource::CurseForge->value)
                ->field('select', [
                    ['value' => ModpackSource::CurseForge->value, 'label' => 'CurseForge'],
                    ['value' => ModpackSource::Modrinth->value, 'label' => 'Modrinth'],
                ])
                ->label('Default source')
                ->help('The source the search opens with. CurseForge is the one that can install a server pack.'),
            Setting::make(self::GAME_VERSION, self::GAME_VERSION, '', ['nullable', 'string', 'max:20', 'regex:/\A[0-9A-Za-z.\-]*\z/'])
                ->label('Default Minecraft version')
                ->help('Empty for any version.'),
            Setting::make(self::LOADER, self::LOADER, '')
                ->field('select', [
                    ['value' => '', 'label' => 'Any loader'],
                    ['value' => 'forge', 'label' => 'Forge'],
                    ['value' => 'neoforge', 'label' => 'NeoForge'],
                    ['value' => 'fabric', 'label' => 'Fabric'],
                    ['value' => 'quilt', 'label' => 'Quilt'],
                ])
                ->label('Default mod loader'),
        ]);
    }

    /** The defaults of one server. */
    public static function for(Server $server): ExtensionSettingsDefinition
    {
        return self::definition()->forServer($server);
    }

    /**
     * The values as the API and the search form name them.
     *
     * @return array{default_source: string, default_game_version: string, default_loader: string}
     */
    public static function values(ExtensionSettingsDefinition $defaults): array
    {
        return [
            self::SOURCE => (string) $defaults->get(self::SOURCE),
            self::GAME_VERSION => (string) $defaults->get(self::GAME_VERSION),
            self::LOADER => (string) $defaults->get(self::LOADER),
        ];
    }
}
