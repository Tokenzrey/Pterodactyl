<?php

declare(strict_types=1);

namespace MultiNodeSync\Support;

use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;

/**
 * The S3 settings, each one checked on the way out: a value that is missing or unusable reads as null, and
 * configured() is false until every one is usable. The credentials are only ever handed to the signer.
 */
final readonly class S3Config
{
    public function __construct(
        private ExtensionSettingsDefinition $definition,
    ) {}

    public function configured(): bool
    {
        return $this->endpoint() !== null
            && $this->bucket() !== null
            && $this->accessKey() !== null
            && $this->secretKey() !== null
            && preg_match('/\A[a-z0-9-]{1,64}\z/', $this->region()) === 1;
    }

    /**
     * Scheme, host and optional port, nothing else: no user name or password, path, query or fragment. https unless
     * allow_http_s3 is on.
     */
    public function endpoint(): ?string
    {
        $endpoint = $this->definition->get('s3_endpoint');
        if (! is_string($endpoint) || $endpoint === '') {
            return null;
        }

        $parts = parse_url($endpoint);
        if ($parts === false) {
            return null;
        }

        $scheme = strtolower((string) ($parts['scheme'] ?? ''));
        $host = strtolower((string) ($parts['host'] ?? ''));
        if ($host === '' || ($scheme !== 'https' && ! ($scheme === 'http' && $this->allowHttp()))) {
            return null;
        }
        if (isset($parts['user']) || isset($parts['pass']) || isset($parts['query']) || isset($parts['fragment']) || ! in_array($parts['path'] ?? '', ['', '/'], true)) {
            return null;
        }
        if (preg_match('/\A[a-z0-9.\-]+\z|\A\[[0-9a-f:.]+\]\z/', $host) !== 1) {
            return null;
        }

        return "{$scheme}://{$host}".(isset($parts['port']) ? ":{$parts['port']}" : '');
    }

    public function region(): string
    {
        $region = $this->definition->get('s3_region');

        return is_string($region) && $region !== '' ? $region : 'us-east-1';
    }

    /** 3 to 63 lower-case letters, digits, dots and hyphens, starting and ending with a letter or digit (the S3 naming rules). */
    public function bucket(): ?string
    {
        $bucket = $this->definition->get('s3_bucket');

        return is_string($bucket) && preg_match('/\A[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]\z/', $bucket) === 1 ? $bucket : null;
    }

    public function accessKey(): ?string
    {
        $key = $this->definition->get('s3_access_key');

        return is_string($key) && $key !== '' ? $key : null;
    }

    public function secretKey(): ?string
    {
        $key = $this->definition->get('s3_secret_key');

        return is_string($key) && $key !== '' ? $key : null;
    }

    public function allowHttp(): bool
    {
        return $this->definition->get('allow_http_s3') === true;
    }
}
