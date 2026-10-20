<?php

declare(strict_types=1);

namespace SubdomainManager\Support;

/** The JSON bodies sent to Cloudflare, in one place so the contract is read and tested in one place. */
final class Payloads
{
    /** Marks records this extension made; the server UUID says which server they belong to. */
    private const COMMENT = 'ptero subdomain-manager server=';

    /** @return array<string, mixed> */
    public static function a(string $name, string $ip, int $ttl, string $serverUuid): array
    {
        return [
            'type' => 'A',
            'name' => $name,
            'content' => $ip,
            'ttl' => $ttl,
            'proxied' => false, // game traffic is not HTTP, so it must not go through Cloudflare's proxy
            'comment' => self::COMMENT.$serverUuid,
        ];
    }

    /** @return array<string, mixed> */
    public static function srv(string $name, string $target, int $port, int $ttl): array
    {
        return [
            'type' => 'SRV',
            'name' => $name,
            'ttl' => $ttl,
            'data' => ['priority' => 0, 'weight' => 5, 'port' => $port, 'target' => $target],
        ];
    }
}
