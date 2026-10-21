<?php

declare(strict_types=1);

namespace SubdomainManager\Support;

use Illuminate\Contracts\Validation\ValidationRule;
use Pterodactyl\Services\Extensions\ExtensionSettingDefinition as Setting;
use Pterodactyl\Services\Extensions\ExtensionSettings;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use RuntimeException;

/**
 * Typed access to the extension's settings and the definition the admin form is rendered from. The
 * Cloudflare token is a secret: encrypted at rest, shown as a mask, never sent to a frontend.
 */
final readonly class SubdomainSettings
{
    public const ID = 'subdomain-manager';

    public const MAX_DOMAINS = 20;

    public const MAX_RESERVED = 100;

    public function __construct(private ExtensionSettingsDefinition $definition) {}

    public static function fromRegistry(ExtensionSettingsRegistry $registry): self
    {
        return new self($registry->get(self::ID) ?? throw new RuntimeException('The subdomain-manager settings are not registered.'));
    }

    public static function define(ExtensionSettings $settings): ExtensionSettingsDefinition
    {
        $itemRule = static fn (callable $accepts, string $message): ValidationRule => new class($accepts, $message) implements ValidationRule
        {
            public function __construct(private $accepts, private string $message) {}

            public function validate(string $attribute, mixed $value, \Closure $fail): void
            {
                if (! is_string($value) || ! ($this->accepts)($value)) {
                    $fail($this->message);
                }
            }
        };

        return new ExtensionSettingsDefinition($settings, [
            Setting::make('cloudflare_token', 'cloudflare_token', '', ['nullable', 'string', 'max:255', 'regex:/^[\x21-\x7E]*$/'])
                ->secret()->tab('Cloudflare')->label('API token')
                ->help('Create a token at Cloudflare with only "Zone → DNS → Edit" for the zones below. It is stored encrypted and never shown again.'),
            Setting::make('domains', 'domains', [], [
                static fn (string $attribute, mixed $value, \Closure $fail) => is_array($value) && count(Domains::names($value)) !== count($value)
                    ? $fail('Each entry must be domain:zone_id with a unique domain, a valid host name and a 32 character zone id.')
                    : null,
            ])->list([$itemRule(static fn (string $item): bool => Domains::invalid([$item]) === [], 'Use the form domain:zone_id, for example mc.example.com:023e105f4ecef8ad9ca31a8372d0c353.')], self::MAX_DOMAINS)
                ->tab('Cloudflare')->label('Domains')
                ->help('One per line as domain:zone_id. The zone id is on the right of the zone overview page at Cloudflare.'),
            Setting::make('target_ipv4', 'target_ipv4', '', ['nullable', 'ipv4'])
                ->tab('DNS')->label('Target IPv4 address')
                ->help('The public address of the machine players connect to. Every A record points here.'),
            Setting::make('srv_enabled', 'srv_enabled', true)
                ->field('toggle')->tab('DNS')->label('Create an SRV record')
                ->help('Lets Minecraft clients join with the name alone, without typing the port.'),
            Setting::make('srv_port', 'srv_port', 0, ['nullable', 'integer', 'between:0,65535'])
                ->field('number')->tab('DNS')->label('SRV port')
                ->help('0 (default): every server uses its own primary allocation port, so each server needs its own port open at the router. A fixed number sends every name to that one port, which is only right behind a proxy.'),
            Setting::make('ttl', 'ttl', 120, ['nullable', 'integer', static fn (string $attribute, mixed $value, \Closure $fail) => $value === null || $value === 1 || ($value >= 60 && $value <= 86400)
                ? null
                : $fail('The TTL must be 1 (automatic) or between 60 and 86400 seconds.')])
                ->field('number')->tab('DNS')->label('TTL (seconds)')
                ->help('1 means automatic. Existing records keep the TTL they were made with.'),
            Setting::make('reserved_labels', 'reserved_labels', Labels::DEFAULT_RESERVED)
                ->list([$itemRule(Labels::isReservedEntry(...), 'Use a plain label (letters, digits, hyphens) or a name starting with an underscore.')], self::MAX_RESERVED)
                ->tab('DNS')->label('Reserved labels')
                ->help('Names that cannot be given to a server, because they usually mean something else on a domain.'),
        ]);
    }

    /** The token, or null while none is stored. */
    public function token(): ?string
    {
        $token = $this->definition->get('cloudflare_token');

        return is_string($token) && $token !== '' ? $token : null;
    }

    /** @return array<string, string> domain => zone id */
    public function domains(): array
    {
        return Domains::parse($this->list('domains'));
    }

    /** @return list<string> */
    public function reservedLabels(): array
    {
        return array_values(array_filter($this->list('reserved_labels'), is_string(...)));
    }

    public function srvEnabled(): bool
    {
        return $this->definition->get('srv_enabled') !== false;
    }

    public function syncConfig(): SyncConfig
    {
        $port = $this->definition->get('srv_port');
        $ttl = $this->definition->get('ttl');
        $ip = $this->definition->get('target_ipv4');

        return new SyncConfig(
            $this->domains(),
            is_string($ip) ? trim($ip) : '',
            $this->srvEnabled(),
            is_numeric($port) ? (int) $port : 0,
            is_numeric($ttl) ? (int) $ttl : 120,
        );
    }

    /** @return array<mixed> */
    private function list(string $key): array
    {
        $value = $this->definition->get($key);

        return is_array($value) ? $value : [];
    }
}
