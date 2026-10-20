<?php

declare(strict_types=1);

namespace SubdomainManager\Support;

/** Rules for the label in front of a configured domain (`kampung` in `kampung.mc.example.com`). */
final class Labels
{
    /** One DNS label: lower-case letters, digits and inner hyphens, 1 to 63 characters. `D` stops a trailing newline matching. */
    public const PATTERN = '/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/D';

    /** Service-style names (`_dmarc`): an underscore, then letters, digits, hyphens or underscores. */
    private const RESERVED_SERVICE_PATTERN = '/^_[a-z0-9_-]{1,62}$/D';

    /** Names that identify other services on a domain; handing one to a game server would be a takeover. */
    public const DEFAULT_RESERVED = [
        'www', 'mail', 'smtp', 'imap', 'pop', 'pop3', 'webmail', 'mx', 'ns', 'ns1', 'ns2', 'ns3', 'ns4',
        'ftp', 'sftp', 'ssh', 'vpn', 'api', 'admin', 'administrator', 'panel', 'wings', 'node', 'cdn', 'static', 'assets',
        'status', 'support', 'help', 'billing', 'dashboard', 'login', 'auth', 'sso', 'git', 'dev', 'staging', 'test',
        'autodiscover', 'autoconfig', 'localhost', 'root', 'postmaster', 'hostmaster', 'webmaster',
        '_dmarc', '_domainkey', '_acme-challenge', '_minecraft', '_tcp', '_udp',
    ];

    /**
     * @param  array<mixed>  $reserved  names an administrator keeps for themselves; compared without regard to case
     * @return 'invalid'|'reserved'|null
     */
    public static function problem(string $label, array $reserved): ?string
    {
        if (preg_match(self::PATTERN, $label) !== 1) {
            return 'invalid';
        }

        $reserved = array_map(strtolower(...), array_filter($reserved, is_string(...)));

        return in_array($label, $reserved, true) ? 'reserved' : null;
    }

    /** Whether an entry of the reserved list is well formed: a label, or an underscore name. */
    public static function isReservedEntry(string $entry): bool
    {
        return preg_match(self::PATTERN, $entry) === 1 || preg_match(self::RESERVED_SERVICE_PATTERN, $entry) === 1;
    }

    public static function fqdn(string $label, string $domain): string
    {
        return strtolower($label.'.'.$domain);
    }

    /** The name of the SRV record Minecraft clients look up for a host name. */
    public static function srvName(string $fqdn): string
    {
        return '_minecraft._tcp.'.$fqdn;
    }
}
