<?php

declare(strict_types=1);

namespace MinecraftSuite\Fields;

use Illuminate\Container\Attributes\CurrentUser;
use MinecraftSuite\Support\MinecraftSuiteSettings;
use Pterodactyl\Extensions\Fields;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Extensions\ExtensionSettingDefinition;

/**
 * The RCON and TPS fields on the admin server form. Only root administrators may set them: the password is a key
 * to the game console, and the host decides where the Panel connects (NFR-MS3).
 */
final class RconFields extends Fields
{
    private const KEYS = ['rcon_host', 'rcon_port', 'rcon_password', 'tps_command', 'poll_interval', 'cache_seconds'];

    /** @return array<string, mixed> */
    public function rules(?Server $server, MinecraftSuiteSettings $settings): array
    {
        return $settings->definition()->validationRules();
    }

    public function authorize(#[CurrentUser] User $admin): bool
    {
        return (bool) $admin->root_admin;
    }

    /** @return array<string, mixed> The password is a mask while one is stored, so it can be left as it is. */
    public function values(Server $server, MinecraftSuiteSettings $settings): array
    {
        $stored = $settings->forServer($server);
        $values = [];
        foreach (self::KEYS as $key) {
            $values[$key] = $stored->get($key);
        }
        $values['rcon_password'] = ($values['rcon_password'] ?? '') === '' ? '' : ExtensionSettingDefinition::MASK;

        return $values;
    }

    /** @param array<string, mixed> $values */
    public function save(Server $server, MinecraftSuiteSettings $settings, array $values): void
    {
        $settings->forServer($server)->update(array_intersect_key($values, array_flip(self::KEYS)));
    }
}
