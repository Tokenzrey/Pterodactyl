<?php

declare(strict_types=1);

use MultiNodeSync\Support\S3Config;
use MultiNodeSync\Tests\ExtensionTestCase;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

uses(ExtensionTestCase::class);

function s3Config(): S3Config
{
    $registry = app(ExtensionSettingsRegistry::class);

    return new S3Config($registry->get('multi-node-sync'));
}

it('returns false from configured when no credentials are set', function (): void {
    expect(s3Config()->configured())->toBeFalse();
});

it('returns true from configured when all credentials are present', function (): void {
    $this->configure([
        's3_endpoint' => 'https://s3.amazonaws.com',
        's3_region' => 'us-east-1',
        's3_bucket' => 'my-bucket',
        's3_access_key' => 'AKIAIOSFODNN7EXAMPLE',
        's3_secret_key' => 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    ]);

    expect(s3Config()->configured())->toBeTrue();
});

it('returns false from configured when endpoint is missing', function (): void {
    $this->configure([
        's3_bucket' => 'my-bucket',
        's3_access_key' => 'AKIAIOSFODNN7EXAMPLE',
        's3_secret_key' => 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    ]);

    expect(s3Config()->configured())->toBeFalse();
});

it('returns null endpoint for HTTP when allow_http_s3 is false', function (): void {
    $this->configure([
        's3_endpoint' => 'http://localhost:9000',
        'allow_http_s3' => false,
    ]);

    expect(s3Config()->endpoint())->toBeNull();
});

it('returns HTTP endpoint when allow_http_s3 is true', function (): void {
    $this->configure([
        's3_endpoint' => 'http://localhost:9000',
        'allow_http_s3' => true,
    ]);

    expect(s3Config()->endpoint())->toBe('http://localhost:9000');
});

it('returns HTTPS endpoint regardless of allow_http_s3', function (): void {
    $this->configure([
        's3_endpoint' => 'https://s3.amazonaws.com',
        'allow_http_s3' => false,
    ]);

    expect(s3Config()->endpoint())->toBe('https://s3.amazonaws.com');
});

it('returns us-east-1 as default region', function (): void {
    expect(s3Config()->region())->toBe('us-east-1');
});

it('returns the configured region', function (): void {
    $this->configure(['s3_region' => 'eu-west-1']);

    expect(s3Config()->region())->toBe('eu-west-1');
});

it('returns null for access key when not set', function (): void {
    expect(s3Config()->accessKey())->toBeNull();
});

it('returns null for secret key when not set', function (): void {
    expect(s3Config()->secretKey())->toBeNull();
});

it('returns the access key when configured', function (): void {
    $this->configure(['s3_access_key' => 'AKIATEST']);

    expect(s3Config()->accessKey())->toBe('AKIATEST');
});

it('returns the secret key when configured', function (): void {
    $this->configure(['s3_secret_key' => 'secretvalue']);

    expect(s3Config()->secretKey())->toBe('secretvalue');
});

it('does not leak the secret key in the endpoint or bucket output', function (): void {
    $secret = 'SUPERSECRET123456';
    $this->configure([
        's3_endpoint' => 'https://s3.amazonaws.com',
        's3_bucket' => 'my-bucket',
        's3_access_key' => 'access',
        's3_secret_key' => $secret,
    ]);

    $config = s3Config();
    expect($config->endpoint())->not->toContain($secret)
        ->and($config->bucket())->not->toContain($secret)
        ->and($config->region())->not->toContain($secret);
});

it('keeps only scheme, host and port of the endpoint', function (string $given, ?string $expected): void {
    $this->configure(['s3_endpoint' => $given, 'allow_http_s3' => true]);

    expect(s3Config()->endpoint())->toBe($expected);
})->with([
    ['https://s3.amazonaws.com/', 'https://s3.amazonaws.com'],
    ['HTTPS://S3.Amazonaws.COM', 'https://s3.amazonaws.com'],
    ['https://minio.internal:9000', 'https://minio.internal:9000'],
    ['https://[::1]:9000', 'https://[::1]:9000'],
    ['https://user:pass@s3.amazonaws.com', null],
    ['https://user@s3.amazonaws.com', null],
    ['https://s3.amazonaws.com/bucket', null],
    ['https://s3.amazonaws.com?x=1', null],
    ['https://s3.amazonaws.com/#frag', null],
    ['https://s3.amazonaws.com:abc', null],
    ['https://', null],
    ['s3.amazonaws.com', null],
    ['ftp://s3.amazonaws.com', null],
    ['https://exa mple.com', null],
]);

it('is not configured with an HTTP endpoint unless HTTP is allowed', function (): void {
    $this->configure(['s3_endpoint' => 'http://localhost:9000', 's3_bucket' => 'my-bucket', 's3_access_key' => 'a', 's3_secret_key' => 'b']);

    expect(s3Config()->configured())->toBeFalse();

    $this->configure(['allow_http_s3' => true]);

    expect(s3Config()->configured())->toBeTrue();
});

it('accepts bucket names by the S3 rules and nothing else', function (string $bucket, bool $valid): void {
    $this->configure(['s3_bucket' => $bucket]);

    expect(s3Config()->bucket())->toBe($valid ? $bucket : null);
})->with([
    ['my-bucket', true],
    ['a.b-c.d', true],
    ['abc', true],
    [str_repeat('a', 63), true],
    ['ab', false],
    ['My-Bucket', false],
    ['-bucket', false],
    ['bucket-', false],
    ['my_bucket', false],
    ['my/bucket', false],
    ['my bucket', false],
]);

it('is not configured with a region that is not a region name', function (): void {
    $this->configure(['s3_endpoint' => 'https://s3.amazonaws.com', 's3_bucket' => 'my-bucket', 's3_access_key' => 'a', 's3_secret_key' => 'b', 's3_region' => 'us/east']);

    expect(s3Config()->configured())->toBeFalse();

    $this->configure(['s3_region' => 'eu-west-1']);

    expect(s3Config()->configured())->toBeTrue();
});
