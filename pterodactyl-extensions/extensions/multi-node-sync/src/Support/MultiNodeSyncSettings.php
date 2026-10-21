<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

use Pterodactyl\Services\Extensions\ExtensionSettingDefinition as Setting;
use Pterodactyl\Services\Extensions\ExtensionSettings;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use RuntimeException;

final readonly class MultiNodeSyncSettings
{
    public const ID = 'multi-node-sync';

    public function __construct(private ExtensionSettingsDefinition $definition) {}

    public static function fromRegistry(ExtensionSettingsRegistry $registry): self
    {
        return new self($registry->get(self::ID) ?? throw new RuntimeException('The multi-node-sync settings are not registered.'));
    }

    public static function define(ExtensionSettings $settings): ExtensionSettingsDefinition
    {
        return new ExtensionSettingsDefinition($settings, [
            Setting::make('s3_endpoint', 's3_endpoint', '', ['nullable', 'string', 'max:253'])
                ->tab('S3')->label('S3 endpoint')
                ->help('HTTPS endpoint for your S3-compatible storage (AWS, MinIO, Wasabi).'),
            Setting::make('s3_region', 's3_region', 'us-east-1', ['nullable', 'string', 'max:64'])
                ->tab('S3')->label('S3 region'),
            Setting::make('s3_bucket', 's3_bucket', '', ['nullable', 'string', 'max:63'])
                ->tab('S3')->label('S3 bucket'),
            Setting::make('s3_access_key', 's3_access_key', '', ['nullable', 'string', 'max:128'])
                ->secret()->tab('S3')->label('S3 access key')
                ->help('Stored encrypted and never shown again.'),
            Setting::make('s3_secret_key', 's3_secret_key', '', ['nullable', 'string', 'max:128'])
                ->secret()->tab('S3')->label('S3 secret key')
                ->help('Stored encrypted and never shown again.'),
            Setting::make('allow_http_s3', 'allow_http_s3', false)
                ->field('toggle')->tab('S3')->label('Allow HTTP S3 endpoint')
                ->help('For local MinIO. Not recommended for production.'),
            Setting::make('presigned_ttl_minutes', 'presigned_ttl_minutes', 15, ['nullable', 'integer', 'between:5,60'])
                ->field('number')->tab('Limits')->label('Presigned URL TTL (minutes)'),
            Setting::make('max_migration_mb', 'max_migration_mb', 10240, ['nullable', 'integer', 'between:100,102400'])
                ->field('number')->tab('Limits')->label('Max migration size (MB)'),
        ]);
    }

    public function s3Config(): S3Config
    {
        return new S3Config($this->definition);
    }

    public function presignedTtlMinutes(): int
    {
        $value = $this->definition->get('presigned_ttl_minutes');

        return is_numeric($value) ? (int) $value : 15;
    }

    public function maxMigrationMb(): int
    {
        $value = $this->definition->get('max_migration_mb');

        return is_numeric($value) ? (int) $value : 10240;
    }
}
