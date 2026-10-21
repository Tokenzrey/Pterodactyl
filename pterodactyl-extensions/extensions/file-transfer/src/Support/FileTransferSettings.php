<?php

declare(strict_types=1);

namespace FileTransfer\Support;

use Pterodactyl\Services\Extensions\ExtensionSettingDefinition as Setting;
use Pterodactyl\Services\Extensions\ExtensionSettings;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use RuntimeException;

/**
 * The limits an administrator sets. The chunk size and the largest file are also sent to the browser (the uploader
 * cuts the file by them); the other two stay on the server.
 */
final readonly class FileTransferSettings
{
    public const ID = 'file-transfer';

    public function __construct(private ExtensionSettingsDefinition $definition) {}

    public static function fromRegistry(ExtensionSettingsRegistry $registry): self
    {
        return new self($registry->get(self::ID) ?? throw new RuntimeException('The file-transfer settings are not registered.'));
    }

    public static function define(ExtensionSettings $settings): ExtensionSettingsDefinition
    {
        return new ExtensionSettingsDefinition($settings, [
            Setting::make('chunk_size_mb', 'chunk_size_mb', 5, ['nullable', 'integer', 'between:1,10'])
                ->field('number')->frontend()->public()->tab('Upload')->label('Chunk size (MB)')
                ->help('Size of each piece a file is cut into in the browser. Smaller pieces use less memory and retry faster.'),
            Setting::make('max_file_mb', 'max_file_mb', 2048, ['nullable', 'integer', 'between:1,10240'])
                ->field('number')->frontend()->public()->tab('Upload')->label('Largest upload (MB)')
                ->help('The largest file a user can upload in pieces.'),
            Setting::make('max_remote_mb', 'max_remote_mb', 1024, ['nullable', 'integer', 'between:1,10240'])
                ->field('number')->tab('Remote fetch')->label('Largest download (MB)')
                ->help('The largest file the Panel will download from a URL for a user.'),
            Setting::make('cleanup_chunk_age_hours', 'cleanup_chunk_age_hours', 2, ['nullable', 'integer', 'between:1,24'])
                ->field('number')->tab('Maintenance')->label('Clean up after (hours)')
                ->help('Unfinished uploads and downloads older than this are deleted every 30 minutes.'),
        ]);
    }

    public function chunkSizeMb(): int
    {
        return $this->integer('chunk_size_mb', 5);
    }

    public function maxFileMb(): int
    {
        return $this->integer('max_file_mb', 2048);
    }

    public function maxRemoteMb(): int
    {
        return $this->integer('max_remote_mb', 1024);
    }

    public function cleanupChunkAgeHours(): int
    {
        return $this->integer('cleanup_chunk_age_hours', 2);
    }

    /** The stored number, or the default when nothing sensible is stored. */
    private function integer(string $key, int $default): int
    {
        $value = $this->definition->get($key);

        return is_numeric($value) && (int) $value > 0 ? (int) $value : $default;
    }
}
