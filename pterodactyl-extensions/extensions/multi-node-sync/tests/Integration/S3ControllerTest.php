<?php

declare(strict_types=1);

use Illuminate\Support\Facades\Http;
use MultiNodeSync\Tests\ExtensionTestCase;
use Pterodactyl\Models\Node;
use Pterodactyl\Models\Server;

uses(ExtensionTestCase::class);

const S3_CONFIG_URL = '/api/admin/extensions/multi-node-sync/s3/config';
const S3_PRESIGN_URL = '/api/admin/extensions/multi-node-sync/s3/presign';

function configureS3(): void
{
    test()->configure([
        's3_endpoint' => 'https://s3.us-east-1.amazonaws.com',
        's3_region' => 'us-east-1',
        's3_bucket' => 'migration-bucket',
        's3_access_key' => 'AKIAIOSFODNN7EXAMPLE',
        's3_secret_key' => 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    ]);
}

it('returns S3 config without credentials for an admin', function (): void {
    $this->actingAsAdmin();
    configureS3();

    $response = $this->getJson(S3_CONFIG_URL);

    $response->assertOk();
    expect($response->json('configured'))->toBeTrue()
        ->and($response->json('endpoint'))->toBe('https://s3.us-east-1.amazonaws.com')
        ->and($response->json('region'))->toBe('us-east-1')
        ->and($response->json('bucket'))->toBe('migration-bucket')
        ->and($response->json())->not->toHaveKey('access_key')
        ->and($response->json())->not->toHaveKey('secret_key');
});

it('returns configured false when S3 is not set up', function (): void {
    $this->actingAsAdmin();

    $response = $this->getJson(S3_CONFIG_URL);

    $response->assertOk();
    expect($response->json('configured'))->toBeFalse();
});

it('rejects non-admin from S3 config', function (): void {
    $user = \Pterodactyl\Models\User::factory()->create(['root_admin' => false]);
    $this->actingAs($user);

    $this->getJson(S3_CONFIG_URL)->assertForbidden();
});

it('rejects unauthenticated from S3 config', function (): void {
    $this->getJson(S3_CONFIG_URL)->assertUnauthorized();
});

it('generates a presigned URL when S3 is configured', function (): void {
    Http::preventStrayRequests();
    $this->actingAsAdmin();
    configureS3();

    $response = $this->postJson(S3_PRESIGN_URL, [
        'method' => 'PUT',
        'object_key' => 'migrations/server1/backup.zip',
    ]);

    $response->assertOk();
    expect($response->json('url'))->toStartWith('https://s3.us-east-1.amazonaws.com/')
        ->and($response->json('method'))->toBe('PUT')
        ->and($response->json('object_key'))->toBe('migrations/server1/backup.zip')
        ->and($response->json('expires_at'))->not->toBeEmpty();
});

it('returns 503 when S3 is not configured for presign', function (): void {
    $this->actingAsAdmin();

    $response = $this->postJson(S3_PRESIGN_URL, [
        'method' => 'PUT',
        'object_key' => 'migrations/backup.zip',
    ]);

    $response->assertStatus(503);
    expect($response->json('error'))->toBe('s3_not_configured');
});

it('rejects object_key with path traversal', function (): void {
    $this->actingAsAdmin();
    configureS3();

    $response = $this->postJson(S3_PRESIGN_URL, [
        'method' => 'PUT',
        'object_key' => '../../etc/passwd',
    ]);

    $response->assertStatus(422);
});

it('rejects non-admin from presign', function (): void {
    $user = \Pterodactyl\Models\User::factory()->create(['root_admin' => false]);
    $this->actingAs($user);

    $this->postJson(S3_PRESIGN_URL, [
        'method' => 'PUT',
        'object_key' => 'migrations/backup.zip',
    ])->assertForbidden();
});

it('validates method is GET or PUT', function (): void {
    $this->actingAsAdmin();
    configureS3();

    $response = $this->postJson(S3_PRESIGN_URL, [
        'method' => 'DELETE',
        'object_key' => 'migrations/backup.zip',
    ]);

    $response->assertStatus(422);
});

it('does not log the full presigned URL', function (): void {
    Http::preventStrayRequests();
    $this->actingAsAdmin();
    configureS3();

    \Illuminate\Support\Facades\Log::spy();

    $this->postJson(S3_PRESIGN_URL, [
        'method' => 'PUT',
        'object_key' => 'migrations/backup.zip',
    ]);

    \Illuminate\Support\Facades\Log::shouldHaveReceived('info')
        ->withArgs(fn (string $message, array $context) => ! array_key_exists('url', $context))
        ->atLeast()
        ->once();
});
