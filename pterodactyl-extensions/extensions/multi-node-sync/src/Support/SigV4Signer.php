<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

use InvalidArgumentException;

/**
 * AWS Signature Version 4 for a presigned S3 URL (query-string form, path-style: https://host/bucket/key).
 * Only the host header is signed and the payload is UNSIGNED-PAYLOAD, as S3 expects of a presigned URL.
 */
final class SigV4Signer
{
    private const METHODS = ['GET', 'PUT', 'HEAD', 'DELETE'];

    /** The longest a presigned URL may live: seven days. */
    public const MAX_EXPIRES = 604800;

    public static function sign(
        string $method,
        string $endpoint,
        string $region,
        string $bucket,
        string $objectKey,
        string $accessKey,
        string $secretKey,
        int $expires,
        ?string $timestamp = null,
    ): string {
        $parts = parse_url($endpoint);
        if ($parts === false) {
            throw new InvalidArgumentException('Invalid S3 endpoint.');
        }

        $scheme = strtolower((string) ($parts['scheme'] ?? ''));
        $host = strtolower((string) ($parts['host'] ?? ''));
        if (! in_array($scheme, ['http', 'https'], true) || $host === '') {
            throw new InvalidArgumentException('Invalid S3 endpoint.');
        }

        // The Host header a client sends leaves out the port when it is the default for the scheme; sign what is sent.
        $port = $parts['port'] ?? null;
        $hostHeader = $port === null || ($scheme === 'https' && $port === 443) || ($scheme === 'http' && $port === 80) ? $host : "{$host}:{$port}";

        return self::presign(
            $method,
            $scheme,
            $hostHeader,
            '/'.rawurlencode($bucket).'/'.self::encodeObjectKey($objectKey),
            $region,
            $accessKey,
            $secretKey,
            $expires,
            $timestamp ?? gmdate('Ymd\THis\Z'),
        );
    }

    /**
     * Signs an already built host and canonical URI. Public so the algorithm can be checked against the example in the
     * AWS documentation, which uses a virtual-hosted address; sign() is what the extension calls.
     *
     * @internal
     */
    public static function presign(
        string $method,
        string $scheme,
        string $hostHeader,
        string $canonicalUri,
        string $region,
        string $accessKey,
        string $secretKey,
        int $expires,
        string $timestamp,
    ): string {
        if (! in_array($method, self::METHODS, true)) {
            throw new InvalidArgumentException('Unsupported method.');
        }
        if ($expires < 1 || $expires > self::MAX_EXPIRES) {
            throw new InvalidArgumentException('The expiry must be between 1 second and 7 days.');
        }
        if (preg_match('/\A\d{8}T\d{6}Z\z/', $timestamp) !== 1) {
            throw new InvalidArgumentException('Invalid timestamp.');
        }
        if (preg_match('/\A[a-z0-9-]{1,64}\z/', $region) !== 1) {
            throw new InvalidArgumentException('Invalid region.');
        }
        // The access key is part of the credential scope, which is split on "/": it may not contain one, or whitespace.
        if (preg_match('/\A[\x21-\x2e\x30-\x7e]{1,128}\z/', $accessKey) !== 1 || $secretKey === '') {
            throw new InvalidArgumentException('Invalid credentials.');
        }

        $date = substr($timestamp, 0, 8);
        $scope = "{$date}/{$region}/s3/aws4_request";

        // Sorted by name, as the canonical request needs; PHP_QUERY_RFC3986 encodes "/" in the credential as %2F.
        $canonicalQuery = http_build_query([
            'X-Amz-Algorithm' => 'AWS4-HMAC-SHA256',
            'X-Amz-Credential' => "{$accessKey}/{$scope}",
            'X-Amz-Date' => $timestamp,
            'X-Amz-Expires' => $expires,
            'X-Amz-SignedHeaders' => 'host',
        ], '', '&', PHP_QUERY_RFC3986);

        $canonicalRequest = "{$method}\n{$canonicalUri}\n{$canonicalQuery}\nhost:{$hostHeader}\n\nhost\nUNSIGNED-PAYLOAD";
        $stringToSign = "AWS4-HMAC-SHA256\n{$timestamp}\n{$scope}\n".hash('sha256', $canonicalRequest);

        $key = hash_hmac('sha256', $date, "AWS4{$secretKey}", true);
        foreach ([$region, 's3', 'aws4_request'] as $step) {
            $key = hash_hmac('sha256', $step, $key, true);
        }
        $signature = hash_hmac('sha256', $stringToSign, $key);

        return "{$scheme}://{$hostHeader}{$canonicalUri}?{$canonicalQuery}&X-Amz-Signature={$signature}";
    }

    private static function encodeObjectKey(string $objectKey): string
    {
        return implode('/', array_map(rawurlencode(...), explode('/', $objectKey)));
    }
}
