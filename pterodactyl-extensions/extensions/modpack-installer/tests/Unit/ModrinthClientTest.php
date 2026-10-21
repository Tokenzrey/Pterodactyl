<?php

declare(strict_types=1);

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\Request;
use ModpackInstaller\Support\ModpackSource;
use ModpackInstaller\Support\ModpackSourceException;
use ModpackInstaller\Support\ModrinthClient;
use ModpackInstaller\Tests\Fixtures;

function mrHttp(mixed $answer): Factory
{
    $http = new Factory();
    $http->preventStrayRequests();
    $http->fake(['api.modrinth.com/*' => $answer]);

    return $http;
}

/** @return array<string, string> */
function mrQuery(Request $request): array
{
    parse_str((string) parse_url($request->url(), PHP_URL_QUERY), $query);

    return $query;
}

function mrAnswer(array $hits, ?int $total = null): array
{
    return ['hits' => $hits, 'offset' => 0, 'limit' => 20, 'total_hits' => $total ?? count($hits)];
}

it('asks version 2 of the API for modpacks, naming itself, and sends no key', function (): void {
    $http = mrHttp(Factory::response(mrAnswer([])));

    (new ModrinthClient($http))->search('fabulous', null, null, 0);

    $http->assertSent(fn (Request $request): bool => str_starts_with($request->url(), 'https://api.modrinth.com/v2/search?')
        && $request->method() === 'GET'
        && $request->header('User-Agent') === ['pterodactyl-modpack-installer/1.0.0']
        && $request->header('Accept') === ['application/json']
        && $request->header('X-API-Key') === []
        && mrQuery($request)['query'] === 'fabulous'
        && mrQuery($request)['facets'] === '[["project_type:modpack"]]'
        && mrQuery($request)['offset'] === '0'
        && mrQuery($request)['limit'] === '20');
});

it('uses the address of the enum, which is a constant', function (): void {
    expect(ModpackSource::Modrinth->baseUrl())->toBe('https://api.modrinth.com/v2/');
});

it('filters by game version and loader, each as a condition that must hold', function (): void {
    $http = mrHttp(Factory::response(mrAnswer([])));

    (new ModrinthClient($http))->search('fabulous', '1.20.1', 'Fabric', 0);

    $http->assertSent(fn (Request $request): bool => mrQuery($request)['facets'] === '[["project_type:modpack"],["versions:1.20.1"],["categories:fabric"]]');
});

it('ignores a loader it does not know', function (): void {
    $http = mrHttp(Factory::response(mrAnswer([])));

    (new ModrinthClient($http))->search('x', null, 'bukkit', 0);

    $http->assertSent(fn (Request $request): bool => mrQuery($request)['facets'] === '[["project_type:modpack"]]');
});

it('asks for the page it was given', function (): void {
    $http = mrHttp(Factory::response(mrAnswer([])));

    (new ModrinthClient($http))->search('x', null, null, 3);

    $http->assertSent(fn (Request $request): bool => mrQuery($request)['offset'] === '60');
});

it('keeps text with quotes or brackets in the query as text, not as part of the filter', function (): void {
    $http = mrHttp(Factory::response(mrAnswer([])));

    (new ModrinthClient($http))->search('"],["project_type:mod', null, null, 0);

    $http->assertSent(fn (Request $request): bool => mrQuery($request)['query'] === '"],["project_type:mod' && mrQuery($request)['facets'] === '[["project_type:modpack"]]');
});

it('reads a hit, and offers no file, since Modrinth has no server pack', function (): void {
    $page = (new ModrinthClient(mrHttp(Factory::response(mrAnswer([Fixtures::hit()], 57)))))->search('x', null, null, 0);

    expect($page->total)->toBe(57)
        ->and($page->results)->toHaveCount(1)
        ->and($page->results[0]->source)->toBe(ModpackSource::Modrinth)
        ->and($page->results[0]->projectId)->toBe('AANobbMI')
        ->and($page->results[0]->name)->toBe('Fabulously Optimized')
        ->and($page->results[0]->summary)->toBe('Performance.')
        ->and($page->results[0]->downloads)->toBe(1000)
        ->and($page->results[0]->iconUrl)->toBe('https://cdn.modrinth.com/data/AANobbMI/icon.png')
        ->and($page->results[0]->latestFiles)->toBe([]);
});

it('does not pass on an icon that is not https', function (mixed $icon): void {
    $page = (new ModrinthClient(mrHttp(Factory::response(mrAnswer([Fixtures::hit(['icon_url' => $icon])])))))->search('x', null, null, 0);

    expect($page->results[0]->iconUrl)->toBeNull();
})->with([['http://cdn.modrinth.com/a.png'], ['javascript:alert(1)'], [null], [5]]);

it('skips a hit whose id or title is not usable', function (): void {
    $hits = [Fixtures::hit(['project_id' => '../x']), Fixtures::hit(['project_id' => 'short']), Fixtures::hit(['title' => null]), 'text', Fixtures::hit()];

    $page = (new ModrinthClient(mrHttp(Factory::response(mrAnswer($hits)))))->search('x', null, null, 0);

    expect($page->results)->toHaveCount(1);
});

it('answers with no results when there are none (EC-MI1)', function (): void {
    $page = (new ModrinthClient(mrHttp(Factory::response(mrAnswer([])))))->search('zzz', null, null, 0);

    expect($page->results)->toBe([])
        ->and($page->total)->toBe(0);
});

it('is unavailable for any status but 200, and says nothing of the answer (EC-MI2, EC-MI12)', function (int $status): void {
    expect(fn () => (new ModrinthClient(mrHttp(Factory::response(['error' => 'detail'], $status))))->search('x', null, null, 0))->toThrow(ModpackSourceException::class);
})->with([301, 400, 410, 429, 500, 503]);

it('is unavailable for an answer of the wrong shape', function (mixed $body): void {
    expect(fn () => (new ModrinthClient(mrHttp(Factory::response($body))))->search('x', null, null, 0))->toThrow(ModpackSourceException::class);
})->with([
    'no hits' => [['total_hits' => 1]],
    'hits is an object' => [['hits' => ['a' => 1]]],
    'hits is text' => [['hits' => 'x']],
    'text' => ['not json'],
]);

it('is unavailable when the source cannot be reached', function (): void {
    expect(fn () => (new ModrinthClient(mrHttp(fn () => throw new ConnectionException('down'))))->search('x', null, null, 0))->toThrow(ModpackSourceException::class);
});
