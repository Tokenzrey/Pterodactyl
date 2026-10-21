<?php

declare(strict_types=1);

use ModpackInstaller\Support\DownloadUrlValidator;

// T-MI1: the address comes from the source's own answer, and is still only followed on CurseForge's CDN over https.

it('allows https on the CDN domains and their subdomains', function (string $url): void {
    expect(DownloadUrlValidator::validate($url))->toBeNull();
})->with([
    'edge' => 'https://edge.forgecdn.net/files/4000/001/atm9-server.zip',
    'mediafilez' => 'https://mediafilez.forgecdn.net/files/1/2/a.zip',
    'bare domain' => 'https://forgecdn.net/a.zip',
    'curseforge' => 'https://www.curseforge.com/api/v1/mods/1/files/2/download',
    'upper case host' => 'https://EDGE.FORGECDN.NET/a.zip',
    'explicit https port' => 'https://edge.forgecdn.net:443/a.zip',
    'dot after host' => 'https://edge.forgecdn.net./a.zip',
    'query' => 'https://edge.forgecdn.net/a.zip?token=abc',
]);

it('refuses every other address', function (string $url): void {
    expect(DownloadUrlValidator::validate($url))->toBe('invalid_url');
})->with([
    'empty' => '',
    'http' => 'http://edge.forgecdn.net/a.zip',
    'ftp' => 'ftp://edge.forgecdn.net/a.zip',
    'file' => 'file:///etc/passwd',
    'no scheme' => 'edge.forgecdn.net/a.zip',
    'scheme relative' => '//edge.forgecdn.net/a.zip',
    'lookalike suffix' => 'https://evilforgecdn.net/a.zip',
    'domain as a prefix' => 'https://forgecdn.net.evil.test/a.zip',
    'domain in the path' => 'https://evil.test/edge.forgecdn.net/a.zip',
    'domain in the query' => 'https://evil.test/?u=https://edge.forgecdn.net/a.zip',
    'domain in the fragment' => 'https://evil.test#.forgecdn.net',
    'user info' => 'https://user@edge.forgecdn.net/a.zip',
    'user info with the real host last' => 'https://edge.forgecdn.net@evil.test/a.zip',
    'password' => 'https://user:pw@edge.forgecdn.net/a.zip',
    'other port' => 'https://edge.forgecdn.net:8443/a.zip',
    'loopback' => 'https://127.0.0.1/a.zip',
    'metadata' => 'https://169.254.169.254/latest/meta-data/',
    'private' => 'https://10.0.0.5/a.zip',
    'ipv6 loopback' => 'https://[::1]/a.zip',
    'localhost' => 'https://localhost/a.zip',
    'decimal ip' => 'https://2130706433/a.zip',
    'space' => 'https://edge.forgecdn.net/a b.zip',
    'newline' => "https://edge.forgecdn.net/a.zip\n",
    'carriage return' => "https://edge.forgecdn.net/a\r.zip",
    'null byte' => "https://edge.forgecdn.net/a\0.zip",
    'backslash trick' => 'https://evil.test\\@edge.forgecdn.net/a.zip',
    'too long' => 'https://edge.forgecdn.net/'.str_repeat('a', 2050),
]);
