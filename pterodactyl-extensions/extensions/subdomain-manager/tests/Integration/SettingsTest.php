<?php

declare(strict_types=1);

use Pterodactyl\Models\ExtensionSetting;
use Pterodactyl\Models\User;
use SubdomainManager\Support\Labels;
use SubdomainManager\Support\SubdomainSettings;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// Contract table of the specification, NFR-S2, NFR-S6, EC-S6: the settings form, its limits and its secrecy.

const SETTINGS = 'api.admin.extensions.settings';
const UPDATE = 'api.admin.extensions.settings.update';

function settingsSchema(): array
{
    return test()->getJson(route(SETTINGS, ['extension' => 'subdomain-manager']))->assertOk()->json('data.schema');
}

function patchSettings(array $settings)
{
    return test()->patchJson(route(UPDATE, ['extension' => 'subdomain-manager']), ['settings' => $settings]);
}

beforeEach(fn () => $this->actingAsAdmin());

test('the form has the documented settings in two tabs, with the documented defaults', function (): void {
    $schema = settingsSchema();
    $byInput = array_column($schema, null, 'input');

    expect(array_column($schema, 'input'))->toBe(['cloudflare_token', 'domains', 'target_ipv4', 'srv_enabled', 'srv_port', 'ttl', 'reserved_labels']);
    expect(array_values(array_unique(array_column($schema, 'tab'))))->toBe(['Cloudflare', 'DNS']);
    expect($byInput['cloudflare_token']['field'])->toBe('password')
        ->and($byInput['domains']['field'])->toBe('list')->and($byInput['domains']['constraints']['max_items'])->toBe(20)
        ->and($byInput['srv_enabled']['value'])->toBeTrue()
        ->and($byInput['srv_port']['value'])->toBe(25565)
        ->and($byInput['ttl']['value'])->toBe(120)
        ->and($byInput['target_ipv4']['value'])->toBe('')
        ->and($byInput['reserved_labels']['constraints']['max_items'])->toBe(100)
        ->and($byInput['reserved_labels']['value'])->toBe(Labels::DEFAULT_RESERVED);
});

test('nothing on the form is visible outside the admin API: no setting is delivered to the frontend', function (): void {
    foreach (settingsSchema() as $field) {
        expect($field['visibility'])->toBe('admin', $field['input']);
    }
});

test('NFR-S2 the token shows as the mask only, is encrypted at rest, and survives saving the form it was read from', function (): void {
    $this->configureCloudflare();

    $schema = settingsSchema();
    $field = array_column($schema, null, 'input')['cloudflare_token'];
    expect($field['value'])->toBe('********');

    patchSettings(array_column($schema, 'value', 'input'))->assertOk();

    $row = ExtensionSetting::query()->where('extension', 'subdomain-manager')->where('key', 'cloudflare_token')->sole();
    expect($row->is_secret)->toBeTrue()->and($row->value)->not->toContain(self::TOKEN);
    expect($this->settings()->token())->toBe(self::TOKEN);
});

test('an empty token field keeps the stored token', function (?string $blank): void {
    $this->configureCloudflare();

    patchSettings(['cloudflare_token' => $blank, 'ttl' => 300])->assertOk();

    expect($this->settings()->token())->toBe(self::TOKEN)->and($this->settings()->syncConfig()->ttl)->toBe(300);
})->with(['', null, '   ']);

test('only administrators can read or change the settings', function (): void {
    $this->actingAs(User::factory()->create(['root_admin' => false]));

    $this->getJson(route(SETTINGS, ['extension' => 'subdomain-manager']))->assertForbidden();
    $this->patchJson(route(UPDATE, ['extension' => 'subdomain-manager']), ['settings' => ['ttl' => 300]])->assertForbidden();
});

describe('NFR-S6 the domain list', function (): void {
    test('good entries are stored and read back as a map of domain to zone', function (): void {
        patchSettings(['domains' => ['MC.example.com:'.FakeCloudflare::ZONE, 'play.example.org: '.FakeCloudflare::OTHER_ZONE]])->assertOk();

        expect($this->settings()->domains())->toBe(['mc.example.com' => FakeCloudflare::ZONE, 'play.example.org' => FakeCloudflare::OTHER_ZONE]);
    });

    test('a bad entry is a 422 on the list', function (string $entry): void {
        $response = patchSettings(['domains' => [$entry]])->assertUnprocessable();

        expect(collect($response->json('errors'))->pluck('meta.source_field')->join(','))->toContain('domains');
    })->with([
        'no zone' => ['mc.example.com'],
        'short zone' => ['mc.example.com:abc'],
        'zone with upper case' => ['mc.example.com:'.'ABCDEFABCDEFABCDEFABCDEFABCDEFAB'],
        'zone not hex' => ['mc.example.com:'.str_repeat('g', 32)],
        'ip instead of a domain' => ['192.168.0.1:'.FakeCloudflare::ZONE],
        'single label' => ['localhost:'.FakeCloudflare::ZONE],
        'a URL' => ['https://mc.example.com:'.FakeCloudflare::ZONE],
        'wildcard' => ['*.example.com:'.FakeCloudflare::ZONE],
    ]); // surrounding whitespace never gets this far: the Panel trims request strings (DomainsTest covers a raw newline)

    test('the same domain twice is a 422', function (): void {
        patchSettings(['domains' => ['mc.example.com:'.FakeCloudflare::ZONE, 'MC.example.com:'.FakeCloudflare::OTHER_ZONE]])->assertUnprocessable();
    });

    test('more than 20 domains is a 422, exactly 20 is fine', function (): void {
        $many = fn (int $n): array => array_map(fn (int $i): string => "d$i.example.com:".FakeCloudflare::ZONE, range(1, $n));

        patchSettings(['domains' => $many(21)])->assertUnprocessable();
        patchSettings(['domains' => $many(20)])->assertOk();
    });
});

describe('the other settings', function (): void {
    test('target_ipv4 must be an IPv4 address (EC-S6)', function (string $value, bool $ok): void {
        $status = patchSettings(['target_ipv4' => $value])->status();

        expect($status)->toBe($ok ? 200 : 422);
    })->with([
        ['203.0.113.10', true], ['', true],
        ['2001:db8::1', false], ['999.1.1.1', false], ['example.com', false], ['203.0.113.10/32', false], ['203.0.113.10:25565', false],
    ]);

    test('srv_port is 0 to 65535', function (mixed $value, bool $ok): void {
        expect(patchSettings(['srv_port' => $value])->status())->toBe($ok ? 200 : 422);
    })->with([[0, true], [25565, true], [65535, true], [-1, false], [65536, false], ['abc', false], [1.5, false]]);

    test('ttl is 1 (automatic) or 60 to 86400', function (mixed $value, bool $ok): void {
        expect(patchSettings(['ttl' => $value])->status())->toBe($ok ? 200 : 422);
    })->with([[1, true], [60, true], [86400, true], [0, false], [2, false], [59, false], [86401, false], [-5, false], ['abc', false]]);

    test('srv_enabled is a boolean', function (): void {
        patchSettings(['srv_enabled' => 'maybe'])->assertUnprocessable();
        patchSettings(['srv_enabled' => false])->assertOk();

        expect($this->settings()->srvEnabled())->toBeFalse();
    });

    test('reserved_labels entries must be labels or underscore names, at most 100', function (): void {
        patchSettings(['reserved_labels' => ['www', '_dmarc', 'ok-1']])->assertOk();
        expect($this->settings()->reservedLabels())->toBe(['www', '_dmarc', 'ok-1']);

        foreach ([['Has Space'], ['a.b'], ['-x'], ['WWW'], [str_repeat('a', 64)], ['']] as $bad) {
            patchSettings(['reserved_labels' => $bad])->assertUnprocessable();
        }
        patchSettings(['reserved_labels' => array_map(fn (int $i): string => "l$i", range(1, 101))])->assertUnprocessable();
    });

    test('the token rejects whitespace and control characters, and is capped', function (string $token): void {
        patchSettings(['cloudflare_token' => $token])->assertUnprocessable();
    })->with(['has space', "new\nline", str_repeat('a', 256), "tab\there"]);

    test('syncConfig turns the stored values into the plain values the syncer needs', function (): void {
        $this->configureCloudflare(['srv_enabled' => false, 'srv_port' => 0, 'ttl' => 600, 'target_ipv4' => ' 203.0.113.10 ']);

        $config = $this->settings()->syncConfig();

        expect($config->domains)->toBe(['mc.example.com' => FakeCloudflare::ZONE])
            ->and($config->targetIpv4)->toBe('203.0.113.10')
            ->and($config->srvEnabled)->toBeFalse()
            ->and($config->srvPort)->toBe(0)
            ->and($config->ttl)->toBe(600)
            ->and($config->problem('mc.example.com'))->toBeNull();
    });

    test('fresh installation: not configured means every sync would fail with a config message, never a Cloudflare call', function (): void {
        $config = SubdomainSettings::fromRegistry($this->app->make(Pterodactyl\Services\Extensions\ExtensionSettingsRegistry::class))->syncConfig();

        expect($config->problem('mc.example.com'))->not->toBeNull()
            ->and($this->settings()->token())->toBeNull();
    });
});
