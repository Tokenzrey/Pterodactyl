<?php

declare(strict_types=1);

use MultiNodeSync\Support\S3Config;
use MultiNodeSync\Support\S3PresignedUrl;
use MultiNodeSync\Tests\ExtensionTestCase;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

uses(ExtensionTestCase::class);

function presigner(): S3PresignedUrl
{
    return new S3PresignedUrl(new S3Config(app(ExtensionSettingsRegistry::class)->get('multi-node-sync')));
}

function configureSigning(array $override = []): void
{
    app(ExtensionSettingsRegistry::class)->get('multi-node-sync')->update(array_merge([
        's3_endpoint' => 'https://s3.eu-west-1.amazonaws.com',
        's3_region' => 'eu-west-1',
        's3_bucket' => 'my-bucket',
        's3_access_key' => 'AKIAIOSFODNN7EXAMPLE',
        's3_secret_key' => 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    ], $override));
}

it('builds a presigned URL for the configured bucket and key', function (): void {
    configureSigning();

    $result = presigner()->generate('PUT', 'migrations/server-1/backup.tar.gz', 15);

    expect($result->url)->toStartWith('https://s3.eu-west-1.amazonaws.com/my-bucket/migrations/server-1/backup.tar.gz?')
        ->and($result->url)->toContain('X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F'.gmdate('Ymd').'%2Feu-west-1%2Fs3%2Faws4_request')
        ->and($result->url)->toContain('X-Amz-Expires=900')
        ->and($result->method)->toBe('PUT')
        ->and($result->objectKey)->toBe('migrations/server-1/backup.tar.gz');
});

it('says when the URL stops working, as many seconds ahead as it was signed for', function (): void {
    configureSigning();

    $result = presigner()->generate('GET', 'a/b.zip', 30);
    $expires = strtotime($result->expiresAt);

    expect($result->expiresAt)->toMatch('/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/')
        ->and($expires - time())->toBeBetween(30 * 60 - 3, 30 * 60);
});

it('signs with the date it reports, so the two cannot disagree', function (): void {
    configureSigning();

    $result = presigner()->generate('GET', 'a/b.zip', 15);
    parse_str((string) parse_url($result->url, PHP_URL_QUERY), $query);

    expect($query['X-Amz-Date'])->toMatch('/\A\d{8}T\d{6}Z\z/')
        ->and(strtotime($result->expiresAt) - strtotime(preg_replace('/\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z\z/', '$1-$2-$3T$4:$5:$6Z', $query['X-Amz-Date'])))->toBe(900);
});

it('never contains the secret key, in the URL or in the result (T-X8)', function (): void {
    configureSigning(['s3_secret_key' => 'SUPERSECRETKEY123456']);

    $result = presigner()->generate('GET', 'a/b.zip', 15);

    expect(json_encode($result))->not->toContain('SUPERSECRETKEY123456');
});

it('refuses a key with traversal, an absolute path or odd characters (AC-MN3, EC-MN9, T-MN6)', function (string $key): void {
    configureSigning();

    expect(fn () => presigner()->generate('GET', $key, 15))->toThrow(InvalidArgumentException::class, 'invalid_path');
})->with(['../etc/passwd', 'a/../b', '/abs/path', 'with space', 'semi;colon', "new\nline", "trailing\n", 'a//b', 'a/./b', 'dir/', '']);

it('refuses a key longer than 1024 characters and accepts one of exactly 1024', function (): void {
    configureSigning();

    expect(presigner()->generate('GET', str_repeat('a', 1024), 15)->objectKey)->toHaveLength(1024)
        ->and(fn () => presigner()->generate('GET', str_repeat('a', 1025), 15))->toThrow(InvalidArgumentException::class);
});

it('allows only GET and PUT', function (string $method): void {
    configureSigning();

    expect(fn () => presigner()->generate($method, 'a/b.zip', 15))->toThrow(InvalidArgumentException::class, 'invalid_method');
})->with(['DELETE', 'POST', 'HEAD', 'get', '']);

it('refuses a lifetime of no time at all or more than the signature allows', function (int $minutes): void {
    configureSigning();

    expect(fn () => presigner()->generate('GET', 'a/b.zip', $minutes))->toThrow(InvalidArgumentException::class, 'invalid_expiry');
})->with([0, -5, 10081]);

it('says s3_not_configured when a setting is missing, without signing anything', function (string $missing): void {
    configureSigning([$missing => '']);

    expect(fn () => presigner()->generate('GET', 'a/b.zip', 15))->toThrow(RuntimeException::class, 's3_not_configured');
})->with(['s3_endpoint', 's3_bucket', 's3_access_key', 's3_secret_key']);

it('says s3_not_configured for an HTTP endpoint unless allow_http_s3 is on', function (): void {
    configureSigning(['s3_endpoint' => 'http://localhost:9000']);

    expect(fn () => presigner()->generate('GET', 'a/b.zip', 15))->toThrow(RuntimeException::class, 's3_not_configured');

    configureSigning(['s3_endpoint' => 'http://localhost:9000', 'allow_http_s3' => true]);

    expect(presigner()->generate('GET', 'a/b.zip', 15)->url)->toStartWith('http://localhost:9000/my-bucket/a/b.zip?');
});

it('says s3_not_configured for a region that is not a region name, instead of failing while signing', function (): void {
    configureSigning(['s3_region' => 'us/east']);

    expect(fn () => presigner()->generate('GET', 'a/b.zip', 15))->toThrow(RuntimeException::class, 's3_not_configured');
});
