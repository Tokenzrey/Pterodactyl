<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

use InvalidArgumentException;
use RuntimeException;

final class S3PresignedUrl
{
    public function __construct(
        private S3Config $config,
    ) {}

    /**
     * @throws InvalidArgumentException when the method, the key or the lifetime is not acceptable
     * @throws RuntimeException 's3_not_configured' when the S3 settings are missing or unusable
     */
    public function generate(string $method, string $objectKey, int $expiresMinutes): PresignedResult
    {
        if (! in_array($method, ['GET', 'PUT'], true)) {
            throw new InvalidArgumentException('invalid_method');
        }

        $pathError = PathValidator::validate($objectKey, 1024);
        if ($pathError !== null) {
            throw new InvalidArgumentException($pathError);
        }

        if ($expiresMinutes < 1 || $expiresMinutes * 60 > SigV4Signer::MAX_EXPIRES) {
            throw new InvalidArgumentException('invalid_expiry');
        }

        $endpoint = $this->config->endpoint();
        $bucket = $this->config->bucket();
        $accessKey = $this->config->accessKey();
        $secretKey = $this->config->secretKey();
        if (! $this->config->configured() || $endpoint === null || $bucket === null || $accessKey === null || $secretKey === null) {
            throw new RuntimeException('s3_not_configured');
        }

        $expires = $expiresMinutes * 60;
        $now = time();

        return new PresignedResult(
            url: SigV4Signer::sign($method, $endpoint, $this->config->region(), $bucket, $objectKey, $accessKey, $secretKey, $expires, gmdate('Ymd\THis\Z', $now)),
            method: $method,
            expiresAt: gmdate('Y-m-d\TH:i:s\Z', $now + $expires),
            objectKey: $objectKey,
        );
    }
}
