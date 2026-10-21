<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

use Illuminate\Contracts\Validation\ValidationRule;
use Pterodactyl\Services\Extensions\ExtensionSettingDefinition as Setting;
use Pterodactyl\Services\Extensions\ExtensionSettings;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use RuntimeException;

final readonly class ModpackSettings
{
    public const ID = 'modpack-installer';

    public const MAX_EXTRA_SANITIZED = 20;

    public function __construct(private ExtensionSettingsDefinition $definition) {}

    public static function fromRegistry(ExtensionSettingsRegistry $registry): self
    {
        return new self($registry->get(self::ID) ?? throw new RuntimeException('The modpack-installer settings are not registered.'));
    }

    public static function define(ExtensionSettings $settings): ExtensionSettingsDefinition
    {
        $filenameRule = new class implements ValidationRule
        {
            public function validate(string $attribute, mixed $value, \Closure $fail): void
            {
                if (! is_string($value) || str_contains($value, '/') || strlen($value) > 64 || $value === '') {
                    $fail('Each entry must be a filename only (no path separators), up to 64 characters.');
                }
            }
        };

        return new ExtensionSettingsDefinition($settings, [
            Setting::make('curseforge_api_key', 'curseforge_api_key', '', ['nullable', 'string', 'max:256'])
                ->secret()->tab('CurseForge')->label('API key')
                ->help('Create an API key at console.curseforge.com. It is stored encrypted and never shown again.'),
            Setting::make('max_download_mb', 'max_download_mb', 512, ['nullable', 'integer', 'between:10,4096'])
                ->field('number')->tab('Limits')->label('Max download size (MB)')
                ->help('Modpacks larger than this are rejected before download.'),
            Setting::make('search_cache_seconds', 'search_cache_seconds', 60, ['nullable', 'integer', 'between:0,300'])
                ->field('number')->tab('Limits')->label('Search cache TTL (seconds)')
                ->help('0 disables caching. Identical searches within this window reuse the cached result.'),
            Setting::make('extra_sanitized_files', 'extra_sanitized_files', [])
                ->list([$filenameRule], self::MAX_EXTRA_SANITIZED)
                ->tab('Sanitizer')->label('Extra sanitized files')
                ->help('Filenames removed from the modpack after extraction, in addition to the defaults (start.sh, run.bat, etc.).'),
        ]);
    }

    public function curseforgeApiKey(): ?string
    {
        $key = $this->definition->get('curseforge_api_key');

        return is_string($key) && $key !== '' ? $key : null;
    }

    public function maxDownloadMb(): int
    {
        $value = $this->definition->get('max_download_mb');

        return is_numeric($value) ? (int) $value : 512;
    }

    public function searchCacheSeconds(): int
    {
        $value = $this->definition->get('search_cache_seconds');

        return is_numeric($value) ? (int) $value : 60;
    }

    /** @return list<string> */
    public function extraSanitizedFiles(): array
    {
        return array_values(array_filter($this->list('extra_sanitized_files'), is_string(...)));
    }

    /** @return array<mixed> */
    private function list(string $key): array
    {
        $value = $this->definition->get($key);

        return is_array($value) ? $value : [];
    }
}
