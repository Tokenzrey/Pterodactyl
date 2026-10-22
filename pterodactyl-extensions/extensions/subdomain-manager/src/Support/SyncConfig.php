<?php

declare(strict_types=1);

namespace SubdomainManager\Support;

/** The settings a sync needs, as plain values so the syncer does not depend on where they are stored. */
final readonly class SyncConfig
{
    /** @param array<string, string> $domains domain => Cloudflare zone id */
    public function __construct(
        public array $domains,
        public string $targetIpv4,
        public bool $srvEnabled,
        public int $srvPort,
        public int $ttl,
        /** Routed mode: no A record per server; the router answers for the name (FR-R3). */
        public bool $routed = false,
    ) {}

    public function zoneFor(string $domain): ?string
    {
        return $this->domains[strtolower($domain)] ?? null;
    }

    /** What stops records for this domain from being made, or null. Nothing is sent to Cloudflare while this is not null (EC-S6). */
    public function problem(string $domain): ?string
    {
        return match (true) {
            filter_var($this->targetIpv4, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false => 'the target IPv4 address is not set or not valid',
            $this->zoneFor($domain) === null => 'the domain is not in the configured domain list',
            $this->ttl !== 1 && ($this->ttl < 60 || $this->ttl > 86400) => 'the TTL must be 1 (automatic) or between 60 and 86400',
            $this->srvPort < 0 || $this->srvPort > 65535 => 'the SRV port must be between 0 and 65535',
            default => null,
        };
    }
}
