<?php

declare(strict_types=1);

use FileTransfer\Support\RemoteUrlValidator;

describe('validate (FR-FT8, T-FT1)', function (): void {
    it('accepts public URLs, on any port (EC-FT13)', function (string $url): void {
        expect(RemoteUrlValidator::validate($url))->toBeNull();
    })->with([
        'https' => ['https://example.com/file.zip'],
        'http with a port' => ['http://example.com:8080/file.zip'],
        'a subdomain' => ['https://cdn.example.co.uk/a/b/c.jar?x=1'],
        'a public IPv4' => ['http://93.184.216.34/file.zip'],
        'a public IPv6' => ['http://[2606:2800:220:1:248:1893:25c8:1946]/file.zip'],
        'a trailing dot' => ['https://example.com./file.zip'],
        'an upper-case host' => ['HTTPS://EXAMPLE.COM/file.zip'],
    ]);

    it('refuses private, loopback, link-local and metadata addresses (AC-FT8, AC-FT9)', function (string $url): void {
        expect(RemoteUrlValidator::validate($url))->toBe('invalid_url');
    })->with([
        'cloud metadata' => ['http://169.254.169.254/latest/meta-data/'],
        'localhost' => ['http://localhost:6379/'],
        'loopback' => ['http://127.0.0.1/'],
        'the whole loopback range' => ['http://127.9.9.9/'],
        '10/8' => ['http://10.0.0.1/'],
        '192.168/16' => ['http://192.168.1.1/'],
        '172.16/12' => ['http://172.16.0.1/'],
        'the top of 172.16/12' => ['http://172.31.255.255/'],
        'unspecified' => ['http://0.0.0.0/'],
        'carrier-grade NAT' => ['http://100.64.0.1/'],
        'multicast' => ['http://224.0.0.1/'],
    ]);

    it('refuses IPv6 addresses written in brackets, which a plain IP check would not see as IPs (T-FT1)', function (string $url): void {
        expect(RemoteUrlValidator::validate($url))->toBe('invalid_url');
    })->with([
        'loopback' => ['http://[::1]:6379/'],
        'unspecified' => ['http://[::]/'],
        'unique local' => ['http://[fc00::1]/'],
        'unique local, fd' => ['http://[fd12:3456::1]/'],
        'link local' => ['http://[fe80::1]/'],
        'IPv4-mapped loopback' => ['http://[::ffff:127.0.0.1]/'],
        'IPv4-mapped private' => ['http://[::ffff:10.0.0.1]/'],
        'IPv4-mapped, hex' => ['http://[::ffff:7f00:1]/'],
        'NAT64 to metadata' => ['http://[64:ff9b::a9fe:a9fe]/'],
        '6to4 to loopback' => ['http://[2002:7f00:1::]/'],
        'multicast' => ['http://[ff02::1]/'],
    ]);

    it('refuses hosts that the system resolver would read as an IP address', function (string $url): void {
        expect(RemoteUrlValidator::validate($url))->toBe('invalid_url');
    })->with([
        'a shortened loopback' => ['http://127.1/'],
        'a decimal address' => ['http://2130706433/'],
        'a hexadecimal address' => ['http://0x7f.0.0.1/'],
        'an octal address' => ['http://0177.0.0.1/'],
    ]);

    it('refuses names that only exist on a private network', function (string $url): void {
        expect(RemoteUrlValidator::validate($url))->toBe('invalid_url');
    })->with([
        'a bare name' => ['http://intranet/'],
        'localhost.localdomain style' => ['http://app.localhost/'],
        '.internal' => ['http://metadata.google.internal/'],
        '.local' => ['http://printer.local/'],
        '.lan' => ['http://nas.lan/'],
    ]);

    it('refuses other schemes, credentials and malformed URLs', function (string $url): void {
        expect(RemoteUrlValidator::validate($url))->toBe('invalid_url');
    })->with([
        'ftp' => ['ftp://example.com/file.zip'],
        'file' => ['file:///etc/passwd'],
        'gopher' => ['gopher://example.com/'],
        'javascript' => ['javascript:alert(1)'],
        'credentials in the URL' => ['https://user:pass@example.com/'],
        'a user only' => ['https://user@example.com/'],
        'credentials that hide a private host' => ['http://example.com@127.0.0.1/'],
        'not a URL' => ['not-a-url'],
        'no host' => ['https:///path'],
        'empty' => [''],
        'a port above 65535' => ['http://example.com:70000/'],
        'a host label too long' => ['http://'.str_repeat('a', 64).'.com/'],
        'a host too long' => ['http://'.str_repeat('a.', 130).'com/'],
        'a leading hyphen' => ['http://-example.com/'],
        'a space in the host' => ['http://exa mple.com/'],
    ]);
});

describe('isPublicIp', function (): void {
    it('is true for public addresses', function (string $ip): void {
        expect(RemoteUrlValidator::isPublicIp($ip))->toBeTrue();
    })->with(['8.8.8.8', '1.1.1.1', '203.0.113.10', '172.15.255.255', '172.32.0.1', '100.63.255.255', '100.128.0.1', '2606:4700:4700::1111', '2001:4860:4860::8888']);

    it('is false for every blocked range, at both of its edges', function (string $ip): void {
        expect(RemoteUrlValidator::isPublicIp($ip))->toBeFalse();
    })->with([
        '10.0.0.0', '10.255.255.255', '172.16.0.0', '172.31.255.255', '192.168.0.0', '192.168.255.255',
        '127.0.0.1', '127.255.255.255', '169.254.169.254', '0.0.0.0', '100.64.0.0', '100.127.255.255',
        '198.18.0.1', '198.19.255.255', '224.0.0.1', '255.255.255.255', '::1', '::', 'fc00::', 'fdff::1', 'fe80::1', 'febf::1',
        '::ffff:1.2.3.4', 'ff02::1',
    ]);

    it('is false for anything that is not an IP address', function (string $value): void {
        expect(RemoteUrlValidator::isPublicIp($value))->toBeFalse();
    })->with(['', 'example.com', '999.1.1.1', '1.2.3', '1.2.3.4.5', '::g', "8.8.8.8\n", '8.8.8.8 ']);
});

describe('resolve (FR-FT10, T-FT2)', function (): void {
    it('returns the addresses of a name that resolves only to public ones', function (): void {
        $lookup = static fn (): array => ['93.184.216.34', '2606:2800:220:1:248:1893:25c8:1946'];

        expect(RemoteUrlValidator::resolve('example.com', $lookup))->toBe(['93.184.216.34', '2606:2800:220:1:248:1893:25c8:1946']);
    });

    it('refuses a name that resolves to a private address, as in DNS rebinding (AC-FT20)', function (): void {
        expect(RemoteUrlValidator::resolve('evil.example.com', static fn (): array => ['127.0.0.1']))->toBeNull();
    });

    it('refuses a name with one private address among public ones: all of them count', function (): void {
        expect(RemoteUrlValidator::resolve('mixed.example.com', static fn (): array => ['93.184.216.34', '10.0.0.5']))->toBeNull();
    });

    it('refuses a name whose IPv6 address is private even when its IPv4 one is public', function (): void {
        expect(RemoteUrlValidator::resolve('v6.example.com', static fn (): array => ['93.184.216.34', '::1']))->toBeNull();
    });

    it('returns an empty list for a name that does not resolve', function (): void {
        expect(RemoteUrlValidator::resolve('nothing.example.com', static fn (): array => []))->toBe([]);
    });

    it('asks nothing for an address: a public one is returned, a private one refused (also in brackets)', function (): void {
        $neverAsked = static fn (): array => throw new RuntimeException('DNS must not be asked for an address');

        expect(RemoteUrlValidator::resolve('93.184.216.34', $neverAsked))->toBe(['93.184.216.34'])
            ->and(RemoteUrlValidator::resolve('[::1]', $neverAsked))->toBeNull()
            ->and(RemoteUrlValidator::resolve('169.254.169.254', $neverAsked))->toBeNull();
    });

    it('passes the host to the lookup without brackets or a trailing dot, in lower case', function (): void {
        $seen = null;
        RemoteUrlValidator::resolve('EXAMPLE.com.', static function (string $host) use (&$seen): array {
            $seen = $host;

            return [];
        });

        expect($seen)->toBe('example.com');
    });
});
