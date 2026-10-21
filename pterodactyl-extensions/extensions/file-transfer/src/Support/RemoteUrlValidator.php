<?php

declare(strict_types=1);

namespace FileTransfer\Support;

use Closure;

/**
 * Decides whether the Panel may fetch a URL for a user (T-FT1 SSRF, T-FT2 DNS rebinding). Two steps, because a name
 * can point anywhere:
 *
 *  - validate(): the URL itself. http(s) only, no credentials, a host that is either a public IP address or a
 *    well-formed public-looking name. No network is touched.
 *  - resolve(): the name's addresses, all of which must be public. The caller then connects to one of THESE
 *    addresses, so a second DNS answer cannot send the request somewhere else.
 *
 * Anything that is not clearly public is refused: a missed private range is a hole, a refused public host is a retry.
 */
final class RemoteUrlValidator
{
    /** Address ranges a user must never be able to make the Panel connect to. */
    private const BLOCKED = [
        '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12',
        '192.0.0.0/24', '192.168.0.0/16', '198.18.0.0/15', '224.0.0.0/4', '240.0.0.0/4',
        // IPv6: unspecified, loopback, IPv4-mapped and NAT64 (they carry an IPv4 address inside), discard, Teredo,
        // 6to4 (also carries IPv4), unique local, link local, deprecated site local, multicast.
        '::/128', '::1/128', '::ffff:0:0/96', '64:ff9b::/96', '64:ff9b:1::/48', '100::/64', '2001::/32', '2002::/16',
        'fc00::/7', 'fe80::/10', 'fec0::/10', 'ff00::/8',
    ];

    /** Names that only exist on a private network. DNS decides in the end; this stops the obvious ones early. */
    private const PRIVATE_SUFFIXES = ['.local', '.localhost', '.internal', '.lan', '.home', '.corp', '.intranet', '.home.arpa'];

    public static function validate(string $url): ?string
    {
        $parts = parse_url($url);
        if ($parts === false || ! isset($parts['scheme'], $parts['host'])) {
            return 'invalid_url';
        }

        if (! in_array(strtolower($parts['scheme']), ['http', 'https'], true) || isset($parts['user']) || isset($parts['pass'])) {
            return 'invalid_url';
        }

        if (isset($parts['port']) && ($parts['port'] < 1 || $parts['port'] > 65535)) {
            return 'invalid_url';
        }

        $host = self::host($parts['host']);
        if ($host === '' || strlen($host) > 253) {
            return 'invalid_url';
        }

        if (filter_var($host, FILTER_VALIDATE_IP) !== false) {
            return self::isPublicIp($host) ? null : 'invalid_url';
        }

        return self::validName($host) ? null : 'invalid_url';
    }

    /** The host as the connection will see it: lower case, without the brackets an IPv6 address has in a URL, without a final dot. */
    public static function host(string $host): string
    {
        return rtrim(strtolower(trim($host, '[]')), '.');
    }

    /** True only for an address that is valid and in none of the blocked ranges. */
    public static function isPublicIp(string $ip): bool
    {
        $packed = filter_var($ip, FILTER_VALIDATE_IP) === false ? false : inet_pton($ip);
        if ($packed === false) {
            return false;
        }

        foreach (self::BLOCKED as $range) {
            if (self::inRange($packed, $range)) {
                return false;
            }
        }

        return true;
    }

    /**
     * The public addresses of a host, or null when any address it has is not public (a rebinding attempt, or simply
     * a private name). An empty list means the name did not resolve at all.
     *
     * @param  (Closure(string): list<string>)|null  $lookup  replaced by tests; DNS A and AAAA records by default
     * @return list<string>|null
     */
    public static function resolve(string $host, ?Closure $lookup = null): ?array
    {
        $host = self::host($host);
        if (filter_var($host, FILTER_VALIDATE_IP) !== false) {
            return self::isPublicIp($host) ? [$host] : null;
        }

        $addresses = ($lookup ?? self::lookup(...))($host);
        foreach ($addresses as $address) {
            if (! self::isPublicIp($address)) {
                return null;
            }
        }

        return array_values($addresses);
    }

    /** @return list<string> */
    private static function lookup(string $host): array
    {
        $records = @dns_get_record($host, DNS_A | DNS_AAAA) ?: [];
        $addresses = [];
        foreach ($records as $record) {
            $address = $record['ip'] ?? $record['ipv6'] ?? null;
            if (is_string($address)) {
                $addresses[] = $address;
            }
        }

        return $addresses;
    }

    /**
     * A name with at least two labels of letters, digits and hyphens, that is not a private suffix and whose labels
     * are not all numbers. The system resolver reads "127.1", "2130706433", "0177.0.0.1" and "0x7f.0.0.1" as IP
     * addresses (inet_aton accepts decimal, octal and hexadecimal parts), so a host like that is refused here.
     */
    private static function validName(string $host): bool
    {
        if (! str_contains($host, '.')) {
            return false;
        }

        $labels = explode('.', $host);
        if (count(array_filter($labels, static fn (string $label): bool => preg_match('/\A(?:0x[0-9a-f]*|[0-9]+)\z/', $label) === 1)) === count($labels)) {
            return false;
        }

        foreach (self::PRIVATE_SUFFIXES as $suffix) {
            if ($host === ltrim($suffix, '.') || str_ends_with($host, $suffix)) {
                return false;
            }
        }

        return preg_match('/\A(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+\z/', $host) === 1;
    }

    private static function inRange(string $packedIp, string $range): bool
    {
        [$network, $bits] = explode('/', $range);
        $packedNetwork = inet_pton($network);
        if ($packedNetwork === false || strlen($packedNetwork) !== strlen($packedIp)) {
            return false;
        }

        $bits = (int) $bits;
        $whole = intdiv($bits, 8);
        if ($whole > 0 && substr($packedIp, 0, $whole) !== substr($packedNetwork, 0, $whole)) {
            return false;
        }

        $rest = $bits % 8;
        if ($rest === 0) {
            return true;
        }

        $mask = (0xFF << (8 - $rest)) & 0xFF;

        return (ord($packedIp[$whole]) & $mask) === (ord($packedNetwork[$whole]) & $mask);
    }
}
