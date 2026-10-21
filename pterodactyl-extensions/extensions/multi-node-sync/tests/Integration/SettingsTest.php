<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Schema;
use MultiNodeSync\Models\Migration;
use MultiNodeSync\Support\MultiNodeSyncSettings;
use MultiNodeSync\Support\WingsFileService;
use MultiNodeSync\Tests\ExtensionTestCase;
use Pterodactyl\Services\Extensions\ExtensionSettings;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;

uses(ExtensionTestCase::class);

it('defines the settings the admin form shows', function (): void {
    $definition = MultiNodeSyncSettings::define(new ExtensionSettings('multi-node-sync'));

    expect($definition)->toBeInstanceOf(ExtensionSettingsDefinition::class);
});

it('never sends the S3 credentials back in the settings response', function (): void {
    $this->actingAsAdmin();
    $this->configure([
        's3_access_key' => 'AKIATEST123',
        's3_secret_key' => 'secretvalue123',
    ]);

    $response = $this->getJson('/api/admin/extensions/multi-node-sync/settings');

    $response->assertOk();
    expect($response->getContent())->not->toContain('secretvalue123')
        ->and($response->getContent())->not->toContain('AKIATEST123');
});

it('returns the configured S3 access key via the settings class', function (): void {
    $this->configure(['s3_access_key' => 'AKIATEST123']);

    $settings = $this->app->make(MultiNodeSyncSettings::class);
    expect($settings->s3Config()->accessKey())->toBe('AKIATEST123');
});

it('returns null access key when not configured', function (): void {
    $settings = $this->app->make(MultiNodeSyncSettings::class);
    expect($settings->s3Config()->accessKey())->toBeNull();
});

it('returns default presigned TTL of 15 minutes', function (): void {
    $settings = $this->app->make(MultiNodeSyncSettings::class);
    expect($settings->presignedTtlMinutes())->toBe(15);
});

it('returns default max migration size of 10240 MB', function (): void {
    $settings = $this->app->make(MultiNodeSyncSettings::class);
    expect($settings->maxMigrationMb())->toBe(10240);
});

it('returns configured values', function (): void {
    $this->configure([
        's3_endpoint' => 'https://s3.eu-west-1.amazonaws.com',
        's3_region' => 'eu-west-1',
        's3_bucket' => 'test-bucket',
        's3_access_key' => 'AKIATEST',
        's3_secret_key' => 'secret',
        'presigned_ttl_minutes' => 30,
        'max_migration_mb' => 5120,
    ]);

    $settings = $this->app->make(MultiNodeSyncSettings::class);
    expect($settings->s3Config()->endpoint())->toBe('https://s3.eu-west-1.amazonaws.com')
        ->and($settings->s3Config()->region())->toBe('eu-west-1')
        ->and($settings->s3Config()->bucket())->toBe('test-bucket')
        ->and($settings->presignedTtlMinutes())->toBe(30)
        ->and($settings->maxMigrationMb())->toBe(5120);
});

it('creates the ext_multi_node_sync_migrations table with the expected schema', function (): void {
    expect(Schema::hasTable('ext_multi_node_sync_migrations'))->toBeTrue();

    $columns = Schema::getColumnListing('ext_multi_node_sync_migrations');
    expect($columns)->toContain('id')
        ->and($columns)->toContain('source_server_id')
        ->and($columns)->toContain('source_server_uuid')
        ->and($columns)->toContain('target_node_id')
        ->and($columns)->toContain('target_allocation_id')
        ->and($columns)->toContain('target_directory')
        ->and($columns)->not->toContain('keep_source')
        ->and($columns)->toContain('status')
        ->and($columns)->toContain('job_id')
        ->and($columns)->toContain('last_error')
        ->and($columns)->toContain('created_at')
        ->and($columns)->toContain('updated_at');
});

it('starts a new migration as pending', function (): void {
    $migration = Migration::query()->create([
        'source_server_id' => 1,
        'source_server_uuid' => '550e8400-e29b-41d4-a716-446655440000',
        'target_node_id' => 2,
        'target_allocation_id' => 3,
    ]);

    expect($migration->status)->toBe('pending');
});

it('can create update and delete migration records', function (): void {
    $migration = Migration::query()->create([
        'source_server_id' => 1,
        'source_server_uuid' => '550e8400-e29b-41d4-a716-446655440000',
        'target_node_id' => 2,
        'target_allocation_id' => 3,
    ]);

    $migration->update(['status' => Migration::RUNNING, 'job_id' => 'job-uuid-123']);
    expect(Migration::query()->find($migration->id)->status)->toBe(Migration::RUNNING);

    $migration->update(['status' => Migration::COMPLETED]);
    expect(Migration::query()->find($migration->id)->status)->toBe(Migration::COMPLETED);

    $migration->delete();
    expect(Migration::query()->find($migration->id))->toBeNull();
});

it('can resolve WingsFileService interface from the container', function (): void {
    $service = $this->app->make(WingsFileService::class);

    expect($service)->toBeInstanceOf(WingsFileService::class);
});
