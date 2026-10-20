<?php

declare(strict_types=1);

use Illuminate\Support\Str;
use Pterodactyl\Models\User;
use SubdomainManager\Models\Record;
use SubdomainManager\Tests\ExtensionTestCase;
use SubdomainManager\Tests\FakeCloudflare;

uses(ExtensionTestCase::class);

// FR-S10, AC-S12, AC-S13, NFR-S3: GET /config and GET /availability on the admin API.

const CFG = '/api/admin/extensions/subdomain-manager/config';
const AVAIL = '/api/admin/extensions/subdomain-manager/availability';

function availability(array $query): string
{
    return AVAIL.'?'.http_build_query($query);
}

beforeEach(function (): void {
    $this->configureCloudflare();
    $this->cf = (new FakeCloudflare)->install();
});

describe('access (AC-S12)', function (): void {
    test('guests get 401 and ordinary users 403 on both endpoints', function (string $url): void {
        $this->getJson($url)->assertUnauthorized();

        $this->actingAs(User::factory()->create(['root_admin' => false]));
        $this->getJson($url)->assertForbidden();
        expect($this->cf->calls)->toBe([]);
    })->with([CFG, AVAIL.'?domain=mc.example.com&label=kampung']);
});

describe('config (AC-S13)', function (): void {
    test('it lists the domain names, the SRV switch and the reserved labels, and nothing else', function (): void {
        $this->actingAsAdmin();
        $this->configure(['domains' => ['mc.example.com:'.FakeCloudflare::ZONE, 'play.example.org:'.FakeCloudflare::OTHER_ZONE], 'reserved_labels' => ['www', 'mail'], 'srv_enabled' => false]);

        $response = $this->getJson(CFG)->assertOk();

        expect($response->json())->toBe(['domains' => ['mc.example.com', 'play.example.org'], 'srv_enabled' => false, 'reserved_labels' => ['www', 'mail']]);
    });

    test('AC-S13 FR-S12 neither the token nor a zone id is in the body, and no header gives them away', function (): void {
        $this->actingAsAdmin();

        $response = $this->getJson(CFG)->assertOk();

        expect($response->getContent())->not->toContain(self::TOKEN)->not->toContain(FakeCloudflare::ZONE);
        expect(json_encode($response->headers->all(), JSON_THROW_ON_ERROR))->not->toContain(self::TOKEN);
    });

    test('with nothing configured it answers with empty lists, not an error', function (): void {
        $this->actingAsAdmin();
        $this->configure(['domains' => []]);

        $this->getJson(CFG)->assertOk()->assertJsonPath('domains', []);
    });
});

describe('availability (FR-S10)', function (): void {
    beforeEach(fn () => $this->actingAsAdmin());

    test('a free name is available and Cloudflare was asked', function (): void {
        $this->getJson(availability(['domain' => 'mc.example.com', 'label' => 'kampung']))->assertOk()
            ->assertExactJson(['available' => true, 'reason' => null, 'checked_cloudflare' => true]);

        expect($this->cf->count('GET', 'A'))->toBe(1)->and($this->cf->count('GET', 'SRV'))->toBe(1);
    });

    test('a domain that is not configured is unconfigured, and Cloudflare is not asked', function (): void {
        $this->getJson(availability(['domain' => 'evil.example.net', 'label' => 'kampung']))->assertOk()
            ->assertJsonPath('available', false)->assertJsonPath('reason', 'unconfigured');

        expect($this->cf->calls)->toBe([]);
    });

    test('a label that breaks the rules is invalid, a reserved one reserved; Cloudflare is not asked', function (string $label, string $reason): void {
        $this->getJson(availability(['domain' => 'mc.example.com', 'label' => $label]))->assertOk()
            ->assertJsonPath('available', false)->assertJsonPath('reason', $reason);

        expect($this->cf->calls)->toBe([]);
    })->with([['Kampung', 'invalid'], ['a_b', 'invalid'], ['-a', 'invalid'], ['www', 'reserved'], ['mail', 'reserved']]);

    test('the domain is matched without regard to case', function (): void {
        $this->getJson(availability(['domain' => 'MC.Example.COM', 'label' => 'kampung']))->assertOk()->assertJsonPath('available', true);
    });

    test('a name held by another server is taken, and Cloudflare is not asked', function (): void {
        Record::query()->create(['server_id' => null, 'server_uuid' => (string) Str::uuid(), 'domain' => 'mc.example.com', 'label' => 'kampung', 'zone_id' => FakeCloudflare::ZONE, 'status' => 'active']);

        $this->getJson(availability(['domain' => 'mc.example.com', 'label' => 'kampung']))->assertOk()
            ->assertJsonPath('available', false)->assertJsonPath('reason', 'taken');

        expect($this->cf->calls)->toBe([]);
    });

    test('the server being edited may keep its own name, with no Cloudflare call', function (): void {
        $server = $this->createServerModel();
        Record::query()->create(['server_id' => $server->id, 'server_uuid' => $server->uuid, 'domain' => 'mc.example.com', 'label' => 'kampung', 'zone_id' => FakeCloudflare::ZONE, 'status' => 'active', 'synced_name' => 'kampung.mc.example.com']);

        $this->getJson(availability(['domain' => 'mc.example.com', 'label' => 'kampung', 'server' => $server->id]))->assertOk()
            ->assertJsonPath('available', true);

        expect($this->cf->calls)->toBe([]);
    });

    test('another server cannot claim it just by passing its own id', function (): void {
        $owner = $this->createServerModel();
        $other = $this->createServerModel();
        Record::query()->create(['server_id' => $owner->id, 'server_uuid' => $owner->uuid, 'domain' => 'mc.example.com', 'label' => 'kampung', 'zone_id' => FakeCloudflare::ZONE, 'status' => 'active', 'synced_name' => 'kampung.mc.example.com']);

        $this->getJson(availability(['domain' => 'mc.example.com', 'label' => 'kampung', 'server' => $other->id]))->assertOk()
            ->assertJsonPath('reason', 'taken');
    });

    test('a name that already exists at Cloudflare and is not ours is flagged', function (string $type, string $name): void {
        $this->cf->seed($type, $name);

        $this->getJson(availability(['domain' => 'mc.example.com', 'label' => 'kampung']))->assertOk()
            ->assertJsonPath('available', false)->assertJsonPath('reason', 'exists_at_cloudflare');
    })->with([['A', 'kampung.mc.example.com'], ['SRV', '_minecraft._tcp.kampung.mc.example.com']]);

    test('an SRV record is not looked for when SRV is switched off', function (): void {
        $this->configure(['srv_enabled' => false]);
        $this->cf->seed('SRV', '_minecraft._tcp.kampung.mc.example.com');

        $this->getJson(availability(['domain' => 'mc.example.com', 'label' => 'kampung']))->assertOk()->assertJsonPath('available', true);
    });

    test('with Cloudflare down the name is reported available but unchecked (the sync checks again before creating)', function (): void {
        $this->cf->failNext('GET', 503);

        $this->getJson(availability(['domain' => 'mc.example.com', 'label' => 'kampung']))->assertOk()
            ->assertExactJson(['available' => true, 'reason' => null, 'checked_cloudflare' => false]);
    });

    test('with no token the name is reported available but unchecked, without a Cloudflare call', function (): void {
        $this->app->make(Pterodactyl\Services\Extensions\ExtensionRepository::class)->settings('subdomain-manager')->setSecret('cloudflare_token', '');

        $this->getJson(availability(['domain' => 'mc.example.com', 'label' => 'kampung']))->assertOk()
            ->assertJsonPath('available', true)->assertJsonPath('checked_cloudflare', false);

        expect($this->cf->calls)->toBe([]);
    });

    test('missing or malformed parameters are a 422', function (array $query): void {
        $this->getJson(availability($query))->assertUnprocessable();

        expect($this->cf->calls)->toBe([]);
    })->with([
        'nothing' => [[]],
        'no label' => [['domain' => 'mc.example.com']],
        'no domain' => [['label' => 'kampung']],
        'label too long' => [['domain' => 'mc.example.com', 'label' => str_repeat('a', 64)]],
        'server not a number' => [['domain' => 'mc.example.com', 'label' => 'kampung', 'server' => 'abc']],
        'label as list' => [['domain' => 'mc.example.com', 'label' => ['a']]],
    ]);

    test('NFR-S3 the 31st request within a minute is throttled', function (): void {
        for ($i = 1; $i <= 30; $i++) {
            $this->getJson(availability(['domain' => 'evil.example.net', 'label' => 'kampung']))->assertOk();
        }

        $this->getJson(availability(['domain' => 'evil.example.net', 'label' => 'kampung']))->assertStatus(429);
        $this->getJson(CFG)->assertStatus(429);
    });

    test('the answer never contains the token or a zone id', function (): void {
        $this->cf->seed('A', 'kampung.mc.example.com');

        $body = $this->getJson(availability(['domain' => 'mc.example.com', 'label' => 'kampung']))->assertOk()->getContent();

        expect($body)->not->toContain(self::TOKEN)->not->toContain(FakeCloudflare::ZONE);
    });
});
