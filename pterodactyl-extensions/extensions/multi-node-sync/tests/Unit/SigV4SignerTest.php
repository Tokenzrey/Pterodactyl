<?php

declare(strict_types=1);

use MultiNodeSync\Support\SigV4Signer;

// AC-MN20, NFR-MN8: the signature must be the one AWS computes. The expected values come from the example in the AWS
// documentation ("Authenticating Requests: Using Query Parameters") and from an independent implementation in Python.

const AWS_ACCESS = 'AKIAIOSFODNN7EXAMPLE';
const AWS_SECRET = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';

function sigv4Signature(string $url): string
{
    preg_match('/X-Amz-Signature=([0-9a-f]+)\z/', $url, $match);

    return $match[1] ?? '';
}

describe('the algorithm', function (): void {
    it('matches the example in the AWS documentation', function (): void {
        $url = SigV4Signer::presign('GET', 'https', 'examplebucket.s3.amazonaws.com', '/test.txt', 'us-east-1', AWS_ACCESS, AWS_SECRET, 86400, '20130524T000000Z');

        expect(sigv4Signature($url))->toBe('aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404')
            ->and($url)->toBe('https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
    });

    it('matches an independent implementation for a path-style GET', function (): void {
        $url = SigV4Signer::sign('GET', 'https://s3.us-east-1.amazonaws.com', 'us-east-1', 'my-bucket', 'migrations/backup.zip', AWS_ACCESS, AWS_SECRET, 900, '20260101T120000Z');

        expect(sigv4Signature($url))->toBe('7d52d78fac6e41609fb70fba4164cd6d781013db81f4ef223261a457d23b1d80');
    });

    it('matches an independent implementation for a PUT to a local endpoint with a port and an encoded key', function (): void {
        $url = SigV4Signer::sign('PUT', 'http://localhost:9000', 'eu-west-1', 'backups', 'server-1/a b.tar.gz', 'minioadmin', 'minioadmin-secret', 3600, '20260315T081500Z');

        expect(sigv4Signature($url))->toBe('2bf24d5713f395a2a8594d6601cb67d136596ae6f58d20c38c448226c2044600')
            ->and($url)->toStartWith('http://localhost:9000/backups/server-1/a%20b.tar.gz?');
    });

    it('signs the host as a client sends it: without the default port, in lower case', function (): void {
        $plain = SigV4Signer::sign('GET', 'https://s3.example.com', 'us-east-1', 'b', 'k', AWS_ACCESS, AWS_SECRET, 60, '20260101T000000Z');
        $default = SigV4Signer::sign('GET', 'https://S3.Example.com:443', 'us-east-1', 'b', 'k', AWS_ACCESS, AWS_SECRET, 60, '20260101T000000Z');

        expect(sigv4Signature($plain))->toBe('fb42d82ba487d908965328d3fc2908ad4838afb60e5e0ae4721c9a2416e3e8fe')
            ->and($default)->toBe($plain);
    });

    it('signs a non-default port, since the client sends it', function (): void {
        $url = SigV4Signer::sign('GET', 'https://s3.example.com:8443', 'us-east-1', 'b', 'k', AWS_ACCESS, AWS_SECRET, 60, '20260101T000000Z');

        expect($url)->toStartWith('https://s3.example.com:8443/b/k?')
            ->and(sigv4Signature($url))->not->toBe('fb42d82ba487d908965328d3fc2908ad4838afb60e5e0ae4721c9a2416e3e8fe');
    });
});

describe('the URL', function (): void {
    $sign = fn (array $override = []): string => SigV4Signer::sign(...array_merge([
        'method' => 'GET',
        'endpoint' => 'https://s3.us-east-1.amazonaws.com',
        'region' => 'us-east-1',
        'bucket' => 'my-bucket',
        'objectKey' => 'migrations/backup.zip',
        'accessKey' => AWS_ACCESS,
        'secretKey' => AWS_SECRET,
        'expires' => 900,
        'timestamp' => '20260101T120000Z',
    ], $override));

    it('starts with the endpoint and the bucket, and carries every query parameter SigV4 needs', function () use ($sign): void {
        $url = $sign();

        expect($url)->toStartWith('https://s3.us-east-1.amazonaws.com/my-bucket/migrations/backup.zip?')
            ->and($url)->toContain('X-Amz-Algorithm=AWS4-HMAC-SHA256')
            ->and($url)->toContain('X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20260101%2Fus-east-1%2Fs3%2Faws4_request')
            ->and($url)->toContain('X-Amz-Date=20260101T120000Z')
            ->and($url)->toContain('X-Amz-Expires=900')
            ->and($url)->toContain('X-Amz-SignedHeaders=host')
            ->and($url)->toMatch('/&X-Amz-Signature=[0-9a-f]{64}\z/');
    });

    it('is the same for the same input and different for a different secret, key, method or time', function () use ($sign): void {
        expect($sign())->toBe($sign())
            ->and($sign(['secretKey' => 'another-secret']))->not->toBe($sign())
            ->and($sign(['objectKey' => 'migrations/other.zip']))->not->toBe($sign())
            ->and($sign(['method' => 'PUT']))->not->toBe($sign())
            ->and($sign(['timestamp' => '20260101T120001Z']))->not->toBe($sign());
    });

    it('never contains the secret key (T-X8)', function () use ($sign): void {
        $url = $sign(['secretKey' => 'SUPERSECRETKEY123456']);

        expect($url)->not->toContain('SUPERSECRETKEY123456');
    });

    it('encodes each segment of the key and keeps the slashes', function () use ($sign): void {
        expect($sign(['objectKey' => 'path with spaces/file+1.zip']))->toContain('/my-bucket/path%20with%20spaces/file%2B1.zip?');
    });

    it('encodes the bucket too', function () use ($sign): void {
        expect($sign(['bucket' => 'a b']))->toContain('/a%20b/');
    });
});

describe('what it refuses', function (): void {
    $good = [
        'method' => 'GET',
        'endpoint' => 'https://s3.amazonaws.com',
        'region' => 'us-east-1',
        'bucket' => 'bucket',
        'objectKey' => 'key',
        'accessKey' => 'access',
        'secretKey' => 'secret',
        'expires' => 900,
        'timestamp' => '20260101T120000Z',
    ];

    it('signs the good arguments', function () use ($good): void {
        expect(SigV4Signer::sign(...$good))->toStartWith('https://s3.amazonaws.com/bucket/key?');
    });

    it('refuses a method S3 does not sign this way', function (string $method) use ($good): void {
        expect(fn () => SigV4Signer::sign(...array_merge($good, ['method' => $method])))->toThrow(InvalidArgumentException::class);
    })->with(['POST', 'get', '', "GET\nHost: evil"]);

    it('refuses an endpoint without a scheme or a host', function (string $endpoint) use ($good): void {
        expect(fn () => SigV4Signer::sign(...array_merge($good, ['endpoint' => $endpoint])))->toThrow(InvalidArgumentException::class);
    })->with(['', 's3.amazonaws.com', 'ftp://s3.amazonaws.com', 'https://', '//s3.amazonaws.com']);

    it('refuses an expiry outside 1 second to 7 days', function (int $expires) use ($good): void {
        expect(fn () => SigV4Signer::sign(...array_merge($good, ['expires' => $expires])))->toThrow(InvalidArgumentException::class);
    })->with([0, -1, 604801]);

    it('accepts the edges of that range', function (int $expires) use ($good): void {
        expect(SigV4Signer::sign(...array_merge($good, ['expires' => $expires])))->toContain("X-Amz-Expires={$expires}");
    })->with([1, 604800]);

    it('refuses a timestamp that is not YYYYMMDDTHHMMSSZ', function (string $timestamp) use ($good): void {
        expect(fn () => SigV4Signer::sign(...array_merge($good, ['timestamp' => $timestamp])))->toThrow(InvalidArgumentException::class);
    })->with(['', '2026-01-01T12:00:00Z', '20260101T120000', "20260101T120000Z\n", '20260101T120000Zx']);

    it('refuses a region that could add to the credential scope', function (string $region) use ($good): void {
        expect(fn () => SigV4Signer::sign(...array_merge($good, ['region' => $region])))->toThrow(InvalidArgumentException::class);
    })->with(['', 'us/east', 'US-EAST-1', "us-east-1\n", 'us east']);

    it('refuses an access key that could split the credential scope, and an empty secret', function (string $access, string $secret) use ($good): void {
        expect(fn () => SigV4Signer::sign(...array_merge($good, ['accessKey' => $access, 'secretKey' => $secret])))->toThrow(InvalidArgumentException::class);
    })->with([['', 'secret'], ['a/b', 'secret'], ['a b', 'secret'], ["a\nb", 'secret'], ['access', '']]);

    it('does not put the secret in the message of an exception', function () use ($good): void {
        try {
            SigV4Signer::sign(...array_merge($good, ['secretKey' => 'TOP-SECRET-VALUE', 'expires' => 0]));
        } catch (InvalidArgumentException $exception) {
            expect($exception->getMessage())->not->toContain('TOP-SECRET-VALUE');

            return;
        }

        $this->fail('Expected an InvalidArgumentException.');
    });
});
