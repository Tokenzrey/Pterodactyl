<?php

declare(strict_types=1);

namespace PlayerManager\Support;

use Closure;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionSettingDefinition as Setting;
use Pterodactyl\Services\Extensions\ExtensionSettings;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;

/**
 * The per-server settings: where RCON listens and how the players endpoint behaves. They are saved from the admin
 * server form (RconFields) and read through forServer(). The password is a secret: encrypted at rest, shown as a
 * mask, never sent to a frontend or written to a log (NFR-PM2). The host is only ever read from here (NFR-PM3).
 */
final readonly class PlayerManagerSettings
{
    public const ID = 'player-manager';

    public function __construct(private ExtensionSettings $settings) {}

    public function definition(): ExtensionSettingsDefinition
    {
        $between = static fn (int $low, int $high): Closure => static fn (string $attribute, mixed $value, Closure $fail) => $value === null || $value === '' || (is_numeric($value) && $value >= $low && $value <= $high)
            ? null
            : $fail("Use a number from {$low} to {$high}.");

        return new ExtensionSettingsDefinition($this->settings, [
            Setting::make('rcon_host', 'rcon_host', '', [
                'nullable', 'string', 'max:253',
                static fn (string $attribute, mixed $value, Closure $fail) => $value === null || $value === '' || RconClient::validHost((string) $value)
                    ? null
                    : $fail('Use an IPv4 address, an IPv6 address or a host name, without a scheme or a path.'),
            ])->label('RCON host')->help('Where the Minecraft RCON port can be reached from the Panel. 127.0.0.1 when both run on one machine.'),
            Setting::make('rcon_port', 'rcon_port', null, ['nullable', $between(1, 65535)])
                ->field('number')->label('RCON port')->help('The rcon.port value in server.properties. Not the game port.'),
            Setting::make('rcon_password', 'rcon_password', '', ['nullable', 'string', 'max:256', 'regex:/^[\x21-\x7E ]*$/'])
                ->secret()->label('RCON password')->help('The rcon.password value in server.properties. Stored encrypted and never shown again.'),
            Setting::make('list_command', 'list_command', 'playermanager:players', ['nullable', 'string', 'max:100', 'regex:/^[\x20-\x7E]*$/'])
                ->label('Player list command')->help('What the server answers with a player list. A plugin that answers JSON gives UUIDs and ping; plain "list" gives names only.'),
            Setting::make('poll_interval', 'poll_interval', 10000, ['nullable', $between(5000, 60000)])
                ->field('number')->label('Refresh every (ms)')->help('How often the player list updates while the page is open. 5000 to 60000.'),
            Setting::make('cache_seconds', 'cache_seconds', 3, ['nullable', $between(0, 30)])
                ->field('number')->label('Cache answers for (seconds)')->help('Several viewers share one RCON call inside this window. 0 turns the cache off.'),
        ]);
    }

    public function forServer(Server $server): ExtensionSettingsDefinition
    {
        return $this->definition()->forServer($server);
    }
}
