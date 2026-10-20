<?php

declare(strict_types=1);

use SubdomainManager\Support\Payloads;

// AC-S2, FR-S4: the exact JSON bodies sent to Cloudflare, as in the specification's contract.

test('the A record body matches the contract and is never proxied', function (): void {
    expect(Payloads::a('kampung.mc.example.com', '203.0.113.10', 120, 'c0ffee00-0000-4000-8000-000000000001'))->toBe([
        'type' => 'A',
        'name' => 'kampung.mc.example.com',
        'content' => '203.0.113.10',
        'ttl' => 120,
        'proxied' => false,
        'comment' => 'ptero subdomain-manager server=c0ffee00-0000-4000-8000-000000000001',
    ]);
});

test('the SRV record body matches the contract', function (): void {
    expect(Payloads::srv('_minecraft._tcp.kampung.mc.example.com', 'kampung.mc.example.com', 25565, 120))->toBe([
        'type' => 'SRV',
        'name' => '_minecraft._tcp.kampung.mc.example.com',
        'ttl' => 120,
        'data' => ['priority' => 0, 'weight' => 5, 'port' => 25565, 'target' => 'kampung.mc.example.com'],
    ]);
});

test('JSON encoding keeps proxied as a real boolean and the ports as numbers', function (): void {
    $json = json_encode([Payloads::a('a.example.com', '203.0.113.10', 1, 'u'), Payloads::srv('s.example.com', 'a.example.com', 1, 1)], JSON_THROW_ON_ERROR);

    expect($json)->toContain('"proxied":false')->toContain('"port":1,')->toContain('"ttl":1,');
});

test('ttl 1 means automatic at Cloudflare and is passed through', function (): void {
    expect(Payloads::a('a.example.com', '203.0.113.10', 1, 'u')['ttl'])->toBe(1);
});
