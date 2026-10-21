<?php

declare(strict_types=1);

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use ModpackInstaller\Tests\ExtensionTestCase;
use ModpackInstaller\Tests\Fixtures;

uses(ExtensionTestCase::class);

/** A server and a subuser who may install on it. @return array{0: Pterodactyl\Models\Server, 1: Pterodactyl\Models\User} */
function srSetup(): array
{
    [, $server] = test()->generateTestAccount();

    return [$server, Fixtures::subuser($server, [Fixtures::INSTALL])];
}

function srSearch(Pterodactyl\Models\Server $server, array $query): string
{
    return Fixtures::url($server, 'search').'?'.http_build_query($query);
}

describe('who may search (T-MI5, AC-MI5)', function (): void {
    it('refuses a subuser without the install permission, and asks the source nothing', function (): void {
        $this->configureCurseForge();
        Http::fake();
        [, $server] = $this->generateTestAccount();
        $user = Fixtures::subuser($server, ['file.read']);

        $this->actingAs($user)->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm']))->assertForbidden();

        Http::assertNothingSent();
    });

    it('refuses someone who is not on the server', function (): void {
        $this->configureCurseForge();
        [, $server] = $this->generateTestAccount();

        $this->actingAs(Pterodactyl\Models\User::factory()->create())->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm']))->assertStatus(404);
    });

    it('refuses a guest', function (): void {
        [, $server] = $this->generateTestAccount();

        $this->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm']))->assertUnauthorized();
    });

    it('lets the server owner search without any extra permission', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => Http::response(Fixtures::search([]))]);
        [$owner, $server] = $this->generateTestAccount();

        $this->actingAs($owner)->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm']))->assertOk();
    });
});

describe('CurseForge', function (): void {
    it('answers with the results in the shape of the spec (AC-MI1, FR-MI2)', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => Http::response(Fixtures::search([Fixtures::mod()], 42))]);
        [$server, $user] = srSetup();

        $response = $this->actingAs($user)->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm']))->assertOk();

        // 1.0 is 1 in JSON, so compare as values, not as types.
        expect($response->json())->toEqual([
            'results' => [[
                'source' => 'curseforge',
                'project_id' => '123',
                'name' => 'All the Mods 9',
                'summary' => 'Everything.',
                'downloads' => 5000000,
                'icon_url' => 'https://media.forgecdn.net/avatars/thumbnails/1/2/64/64/atm9.png',
                'latest_files' => [[
                    'file_id' => '4002',
                    'name' => 'atm9-1.0.0.zip',
                    'game_version' => '1.20.1',
                    'loader' => 'forge',
                    'is_server_pack' => true,
                    'file_size_mb' => 1.0,
                ]],
            ]],
            'total' => 42,
            'page' => 0,
        ]);
    });

    it('never puts a download address in the answer', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => Http::response(Fixtures::search([Fixtures::mod()]))]);
        [$server, $user] = srSetup();

        $response = $this->actingAs($user)->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm']))->assertOk();

        expect($response->getContent())->not->toContain('forgecdn.net/files')->and($response->getContent())->not->toContain('download_url');
    });

    it('says curseforge_not_configured, without asking CurseForge, when no key is set (AC-MI3)', function (): void {
        Http::fake();
        [$server, $user] = srSetup();

        $this->actingAs($user)->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm']))->assertStatus(503)->assertExactJson(['error' => 'curseforge_not_configured']);

        Http::assertNothingSent();
    });

    it('sends the stored key to CurseForge and nowhere else', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => Http::response(Fixtures::search([]))]);
        [$server, $user] = srSetup();

        $this->actingAs($user)->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm', 'game_version' => '1.20.1', 'loader' => 'fabric', 'page' => 1]))->assertOk();

        Http::assertSent(fn (Request $request): bool => str_starts_with($request->url(), 'https://api.curseforge.com/v1/mods/search')
            && $request->header('X-API-Key') === [ExtensionTestCase::API_KEY]
            && str_contains($request->url(), 'gameVersion=1.20.1')
            && str_contains($request->url(), 'modLoaderType=4')
            && str_contains($request->url(), 'index=20'));
        Http::assertSentCount(1);
    });

    it('says source_unavailable when CurseForge is down, and not what it said', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => Http::response('stack trace /var/www/secret', 500)]);
        [$server, $user] = srSetup();

        $response = $this->actingAs($user)->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm']))->assertStatus(503);

        expect($response->json())->toBe(['error' => 'source_unavailable'])
            ->and($response->getContent())->not->toContain('/var/www');
    });

    it('says source_unavailable when CurseForge cannot be reached', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => fn () => throw new ConnectionException('timed out')]);
        [$server, $user] = srSetup();

        $this->actingAs($user)->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm']))->assertStatus(503)->assertExactJson(['error' => 'source_unavailable']);
    });

    it('takes the last page CurseForge will answer', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => Http::response(Fixtures::search([]))]);
        [$server, $user] = srSetup();

        $this->actingAs($user)->getJson(srSearch($server, ['source' => 'curseforge', 'query' => 'atm', 'page' => 499]))->assertOk()->assertJsonPath('page', 499);
    });
});

describe('Modrinth', function (): void {
    it('answers with the results, without a key and without any file (AC-MI2)', function (): void {
        Http::fake(['api.modrinth.com/*' => Http::response(['hits' => [Fixtures::hit()], 'total_hits' => 1])]);
        [$server, $user] = srSetup();

        $response = $this->actingAs($user)->getJson(srSearch($server, ['source' => 'modrinth', 'query' => 'fabulous', 'game_version' => '1.20.1', 'loader' => 'fabric']))->assertOk();

        expect($response->json('results.0.name'))->toBe('Fabulously Optimized')
            ->and($response->json('results.0.latest_files'))->toBe([]);
        Http::assertSent(fn (Request $request): bool => str_starts_with($request->url(), 'https://api.modrinth.com/v2/search')
            && $request->header('X-API-Key') === []
            && str_contains(urldecode($request->url()), '"versions:1.20.1"')
            && str_contains(urldecode($request->url()), '"categories:fabric"'));
    });

    it('does not need the CurseForge key', function (): void {
        Http::fake(['api.modrinth.com/*' => Http::response(['hits' => [], 'total_hits' => 0])]);
        [$server, $user] = srSetup();

        $this->actingAs($user)->getJson(srSearch($server, ['source' => 'modrinth', 'query' => 'x']))->assertOk();
    });

    it('says source_unavailable when Modrinth answers with an error (EC-MI2)', function (): void {
        Http::fake(['api.modrinth.com/*' => Http::response(['error' => 'x'], 429)]);
        [$server, $user] = srSetup();

        $this->actingAs($user)->getJson(srSearch($server, ['source' => 'modrinth', 'query' => 'x']))->assertStatus(503)->assertExactJson(['error' => 'source_unavailable']);
    });
});

describe('what it validates (FR-MI1)', function (): void {
    it('refuses what it cannot search for, and asks nobody', function (array $query): void {
        $this->configureCurseForge();
        Http::fake();
        [$server, $user] = srSetup();

        $this->actingAs($user)->getJson(srSearch($server, $query))->assertStatus(422);

        Http::assertNothingSent();
    })->with([
        'no source' => [['query' => 'atm']],
        'unknown source' => [['source' => 'github', 'query' => 'atm']],
        'a URL as the source' => [['source' => 'http://169.254.169.254', 'query' => 'atm']],
        'no query' => [['source' => 'curseforge']],
        'empty query' => [['source' => 'curseforge', 'query' => '']],
        'blank query' => [['source' => 'curseforge', 'query' => '   ']],
        'long query' => [['source' => 'curseforge', 'query' => str_repeat('a', 101)]],
        'unknown loader' => [['source' => 'curseforge', 'query' => 'a', 'loader' => 'bukkit']],
        'odd game version' => [['source' => 'curseforge', 'query' => 'a', 'game_version' => '1.20&gameId=1']],
        'long game version' => [['source' => 'curseforge', 'query' => 'a', 'game_version' => str_repeat('1', 21)]],
        'negative page' => [['source' => 'curseforge', 'query' => 'a', 'page' => -1]],
        'huge page' => [['source' => 'curseforge', 'query' => 'a', 'page' => 500]],
        'page is text' => [['source' => 'curseforge', 'query' => 'a', 'page' => 'x']],
    ]);

    it('takes a query of exactly 100 characters', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => Http::response(Fixtures::search([]))]);
        [$server, $user] = srSetup();

        $this->actingAs($user)->getJson(srSearch($server, ['source' => 'curseforge', 'query' => str_repeat('a', 100)]))->assertOk();
    });
});

describe('the cache (FR-MI3, AC-MI15)', function (): void {
    it('asks the source once for two identical searches, and gives both the same answer', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => Http::response(Fixtures::search([Fixtures::mod()]))]);
        [$server, $user] = srSetup();
        $url = srSearch($server, ['source' => 'curseforge', 'query' => 'atm']);

        $first = $this->actingAs($user)->getJson($url)->assertOk()->json();
        $second = $this->actingAs($user)->getJson($url)->assertOk()->json();

        expect($second)->toBe($first);
        Http::assertSentCount(1);
    });

    it('asks again for a different query, filter, source or page', function (array $other): void {
        $this->configureCurseForge();
        Http::fake(['*' => Http::response(['hits' => [], 'total_hits' => 0] + Fixtures::search([]))]);
        [$server, $user] = srSetup();
        $base = ['source' => 'curseforge', 'query' => 'atm', 'game_version' => '1.20.1', 'loader' => 'forge', 'page' => 0];

        $this->actingAs($user)->getJson(srSearch($server, $base))->assertOk();
        $this->actingAs($user)->getJson(srSearch($server, [...$base, ...$other]))->assertOk();

        Http::assertSentCount(2);
    })->with([
        'query' => [['query' => 'atm2']],
        'game version' => [['game_version' => '1.19.2']],
        'loader' => [['loader' => 'fabric']],
        'source' => [['source' => 'modrinth']],
        'page' => [['page' => 1]],
    ]);

    it('shares the answer between users of the same search', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => Http::response(Fixtures::search([]))]);
        [, $server] = $this->generateTestAccount();
        $a = Fixtures::subuser($server, [Fixtures::INSTALL]);
        $b = Fixtures::subuser($server, [Fixtures::INSTALL]);
        $url = srSearch($server, ['source' => 'curseforge', 'query' => 'atm']);

        $this->actingAs($a)->getJson($url)->assertOk();
        $this->actingAs($b)->getJson($url)->assertOk();

        Http::assertSentCount(1);
    });

    it('does not cache a failure', function (): void {
        $this->configureCurseForge();
        Http::fake(['api.curseforge.com/*' => Http::sequence()->push('', 500)->push(Fixtures::search([]), 200)]);
        [$server, $user] = srSetup();
        $url = srSearch($server, ['source' => 'curseforge', 'query' => 'atm']);

        $this->actingAs($user)->getJson($url)->assertStatus(503);
        $this->actingAs($user)->getJson($url)->assertOk();
    });

    it('does not cache at all when the setting is 0', function (): void {
        $this->configureCurseForge(['search_cache_seconds' => 0]);
        Http::fake(['api.curseforge.com/*' => Http::response(Fixtures::search([]))]);
        [$server, $user] = srSetup();
        $url = srSearch($server, ['source' => 'curseforge', 'query' => 'atm']);

        $this->actingAs($user)->getJson($url)->assertOk();
        $this->actingAs($user)->getJson($url)->assertOk();

        Http::assertSentCount(2);
    });
});

it('is limited to 30 requests a minute, and the 31st is 429 (FR-MI17, AC-MI16)', function (): void {
    $this->configureCurseForge();
    Http::fake(['api.curseforge.com/*' => Http::response(Fixtures::search([]))]);
    [$server, $user] = srSetup();
    $url = srSearch($server, ['source' => 'curseforge', 'query' => 'atm']);

    for ($i = 0; $i < 30; $i++) {
        $this->actingAs($user)->getJson($url)->assertOk();
    }

    $this->actingAs($user)->getJson($url)->assertStatus(429);
});
