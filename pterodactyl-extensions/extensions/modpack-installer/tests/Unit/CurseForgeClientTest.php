<?php

declare(strict_types=1);

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\Request;
use ModpackInstaller\Support\CurseForgeClient;
use ModpackInstaller\Support\ModpackSourceException;
use ModpackInstaller\Tests\Fixtures;

/** A Factory that answers one way and fails any other request. */
function cfHttp(mixed $answer): Factory
{
    $http = new Factory();
    $http->preventStrayRequests();
    $http->fake(['api.curseforge.com/*' => $answer]);

    return $http;
}

function cfClient(Factory $http): CurseForgeClient
{
    return new CurseForgeClient($http, 'secret-key-123');
}

function cfQuery(Request $request): array
{
    parse_str((string) parse_url($request->url(), PHP_URL_QUERY), $query);

    return $query;
}

describe('search', function (): void {
    it('asks the modpacks of Minecraft, with the key and the first page', function (): void {
        $http = cfHttp(Factory::response(Fixtures::search([])));

        cfClient($http)->search('atm', null, null, 0);

        $http->assertSent(fn (Request $request): bool => str_starts_with($request->url(), 'https://api.curseforge.com/v1/mods/search?')
            && $request->method() === 'GET'
            && $request->header('X-API-Key') === ['secret-key-123']
            && $request->header('Accept') === ['application/json']
            && cfQuery($request) === ['gameId' => '432', 'classId' => '4471', 'searchFilter' => 'atm', 'index' => '0', 'pageSize' => '20']);
    });

    it('asks for the page it was given', function (): void {
        $http = cfHttp(Factory::response(Fixtures::search([])));

        cfClient($http)->search('atm', null, null, 2);

        $http->assertSent(fn (Request $request): bool => cfQuery($request)['index'] === '40');
    });

    it('filters by game version, and by loader together with it', function (): void {
        $http = cfHttp(Factory::response(Fixtures::search([])));

        cfClient($http)->search('atm', '1.20.1', 'fabric', 0);

        $http->assertSent(fn (Request $request): bool => cfQuery($request)['gameVersion'] === '1.20.1' && cfQuery($request)['modLoaderType'] === '4');
    });

    it('maps every loader to the number CurseForge uses', function (string $loader, string $number): void {
        $http = cfHttp(Factory::response(Fixtures::search([])));

        cfClient($http)->search('atm', '1.20.1', $loader, 0);

        $http->assertSent(fn (Request $request): bool => cfQuery($request)['modLoaderType'] === $number);
    })->with([['forge', '1'], ['fabric', '4'], ['quilt', '5'], ['neoforge', '6'], ['NeoForge', '6']]);

    it('leaves the loader out when there is no game version, since CurseForge would not apply it', function (): void {
        $http = cfHttp(Factory::response(Fixtures::search([])));

        cfClient($http)->search('atm', null, 'forge', 0);

        $http->assertSent(fn (Request $request): bool => ! array_key_exists('modLoaderType', cfQuery($request)) && ! array_key_exists('gameVersion', cfQuery($request)));
    });

    it('ignores a loader it does not know', function (): void {
        $http = cfHttp(Factory::response(Fixtures::search([])));

        cfClient($http)->search('atm', '1.20.1', 'cauldron', 0);

        $http->assertSent(fn (Request $request): bool => ! array_key_exists('modLoaderType', cfQuery($request)));
    });

    it('reads a project: its name, summary, downloads and an https icon', function (): void {
        $page = cfClient(cfHttp(Factory::response(Fixtures::search([Fixtures::mod()], 1234))))->search('atm', null, null, 0);

        expect($page->total)->toBe(1234)
            ->and($page->results)->toHaveCount(1)
            ->and($page->results[0]->projectId)->toBe('123')
            ->and($page->results[0]->name)->toBe('All the Mods 9')
            ->and($page->results[0]->summary)->toBe('Everything.')
            ->and($page->results[0]->downloads)->toBe(5000000)
            ->and($page->results[0]->iconUrl)->toBe('https://media.forgecdn.net/avatars/thumbnails/1/2/64/64/atm9.png');
    });

    it('does not pass on an icon that is not https', function (mixed $logo): void {
        $page = cfClient(cfHttp(Factory::response(Fixtures::search([Fixtures::mod(['logo' => $logo])]))))->search('atm', null, null, 0);

        expect($page->results[0]->iconUrl)->toBeNull();
    })->with([
        'http' => [['thumbnailUrl' => 'http://media.forgecdn.net/a.png']],
        'javascript' => [['thumbnailUrl' => 'javascript:alert(1)']],
        'data' => [['thumbnailUrl' => 'data:image/png;base64,AAAA']],
        'none' => [null],
        'not a string' => [['thumbnailUrl' => 5]],
    ]);

    it('offers the server pack that a client file points to, under the id of the server pack', function (): void {
        $page = cfClient(cfHttp(Factory::response(Fixtures::search([Fixtures::mod()]))))->search('atm', null, null, 0);
        $file = $page->results[0]->latestFiles[0];

        expect($file->fileId)->toBe('4002')
            ->and($file->isServerPack)->toBeTrue()
            ->and($file->name)->toBe('atm9-1.0.0.zip')
            ->and($file->gameVersion)->toBe('1.20.1')
            ->and($file->loader)->toBe('forge')
            ->and($file->fileSizeMb)->toBe(1.0);
    });

    it('offers a file that is itself a server pack as it is', function (): void {
        $mod = Fixtures::mod(['latestFiles' => [Fixtures::serverPack()]]);
        $file = cfClient(cfHttp(Factory::response(Fixtures::search([$mod]))))->search('atm', null, null, 0)->results[0]->latestFiles[0];

        expect($file->fileId)->toBe('4002')
            ->and($file->isServerPack)->toBeTrue();
    });

    it('shows a client file with no server pack, and says it cannot be installed', function (): void {
        $mod = Fixtures::mod(['latestFiles' => [Fixtures::file(['serverPackFileId' => null])]]);
        $file = cfClient(cfHttp(Factory::response(Fixtures::search([$mod]))))->search('atm', null, null, 0)->results[0]->latestFiles[0];

        expect($file->fileId)->toBe('4001')
            ->and($file->isServerPack)->toBeFalse();
    });

    it('treats a missing or zero server pack id as no server pack', function (mixed $id): void {
        $mod = Fixtures::mod(['latestFiles' => [Fixtures::file(['serverPackFileId' => $id])]]);

        expect(cfClient(cfHttp(Factory::response(Fixtures::search([$mod]))))->search('atm', null, null, 0)->results[0]->latestFiles[0]->isServerPack)->toBeFalse();
    })->with([[null], [0], ['4002'], [-1]]);

    it('skips files that are not available, and shows no more than five', function (): void {
        $files = [Fixtures::file(['id' => 1, 'isAvailable' => false]), ...array_map(fn (int $id): array => Fixtures::file(['id' => $id]), range(10, 17))];
        $mod = Fixtures::mod(['latestFiles' => $files]);

        $offered = cfClient(cfHttp(Factory::response(Fixtures::search([$mod]))))->search('atm', null, null, 0)->results[0]->latestFiles;

        expect($offered)->toHaveCount(5)
            ->and(array_map(fn ($file): string => $file->name, $offered))->each->toBe('atm9-1.0.0.zip');
    });

    it('finds the game version and the loader among a file\'s game versions, in any order', function (): void {
        $mod = Fixtures::mod(['latestFiles' => [Fixtures::file(['gameVersions' => ['Client', 'NeoForge', '1.21', '1.20.4']])]]);
        $file = cfClient(cfHttp(Factory::response(Fixtures::search([$mod]))))->search('atm', null, null, 0)->results[0]->latestFiles[0];

        expect($file->gameVersion)->toBe('1.21')
            ->and($file->loader)->toBe('neoforge');
    });

    it('gives no version or loader when the file names none', function (): void {
        $mod = Fixtures::mod(['latestFiles' => [Fixtures::file(['gameVersions' => ['Client']])]]);
        $file = cfClient(cfHttp(Factory::response(Fixtures::search([$mod]))))->search('atm', null, null, 0)->results[0]->latestFiles[0];

        expect($file->gameVersion)->toBeNull()
            ->and($file->loader)->toBeNull();
    });

    it('answers with no results when there are none (EC-MI1)', function (): void {
        $page = cfClient(cfHttp(Factory::response(Fixtures::search([]))))->search('zzz', null, null, 0);

        expect($page->results)->toBe([])
            ->and($page->total)->toBe(0);
    });

    it('counts what it was given when the answer has no total, and never more than CurseForge will page through', function (): void {
        $body = ['data' => [Fixtures::mod()]];
        $big = Fixtures::search([Fixtures::mod()], 99999);

        expect(cfClient(cfHttp(Factory::response($body)))->search('a', null, null, 0)->total)->toBe(1)
            ->and(cfClient(cfHttp(Factory::response($big)))->search('a', null, null, 0)->total)->toBe(10000);
    });

    it('skips an entry that is not a project, instead of failing the whole page', function (): void {
        $page = cfClient(cfHttp(Factory::response(Fixtures::search(['text', ['id' => 'x', 'name' => 'a'], ['name' => 'no id'], Fixtures::mod()]))))->search('atm', null, null, 0);

        expect($page->results)->toHaveCount(1);
    });

    it('is unavailable for any status but 200 (EC-MI12)', function (int $status): void {
        expect(fn () => cfClient(cfHttp(Factory::response(['error' => 'secret detail'], $status)))->search('atm', null, null, 0))->toThrow(ModpackSourceException::class);
    })->with([301, 302, 400, 401, 403, 404, 429, 500, 502, 503]);

    it('is unavailable for an answer of the wrong shape (EC-MI12)', function (mixed $body): void {
        expect(fn () => cfClient(cfHttp(Factory::response($body)))->search('atm', null, null, 0))->toThrow(ModpackSourceException::class);
    })->with([
        'no data' => [['pagination' => []]],
        'data is an object' => [['data' => ['a' => 1]]],
        'data is text' => [['data' => 'x']],
        'a list' => [[1, 2]],
        'text' => ['not json'],
    ]);

    it('is unavailable when the source cannot be reached', function (): void {
        $http = cfHttp(fn () => throw new ConnectionException('cURL error 6: could not resolve host'));

        expect(fn () => cfClient($http)->search('atm', null, null, 0))->toThrow(ModpackSourceException::class);
    });

    it('says nothing of what the source or the network answered', function (): void {
        try {
            cfClient(cfHttp(Factory::response('internal path /var/www', 500)))->search('atm', null, null, 0);
        } catch (ModpackSourceException $exception) {
            expect($exception->getMessage())->not->toContain('/var/www')->and($exception->errorCode())->toBe('source_unavailable');

            return;
        }

        $this->fail('Expected an exception.');
    });
});

describe('pageInRange', function (): void {
    it('allows the pages CurseForge will answer', function (int $page, bool $allowed): void {
        expect(CurseForgeClient::pageInRange($page))->toBe($allowed);
    })->with([[0, true], [1, true], [499, true], [500, false], [10000, false], [-1, false]]);
});

describe('file', function (): void {
    it('asks for the file of the project by id', function (): void {
        $http = cfHttp(Factory::response(['data' => Fixtures::serverPack()]));

        cfClient($http)->file('123', '4002');

        $http->assertSent(fn (Request $request): bool => $request->url() === 'https://api.curseforge.com/v1/mods/123/files/4002' && $request->header('X-API-Key') === ['secret-key-123']);
    });

    it('describes the file: server pack, address, size and SHA-1', function (): void {
        $file = cfClient(cfHttp(Factory::response(['data' => Fixtures::serverPack()])))->file('123', '4002');

        expect($file->fileId)->toBe('4002')
            ->and($file->name)->toBe('atm9-server-1.0.0.zip')
            ->and($file->isServerPack)->toBeTrue()
            ->and($file->downloadUrl)->toBe(Fixtures::CDN)
            ->and($file->sizeBytes)->toBe(1048576)
            ->and($file->sha1)->toBe(sha1('pack'));
    });

    it('says a client file is not a server pack', function (): void {
        $file = cfClient(cfHttp(Factory::response(['data' => Fixtures::file()])))->file('123', '4001');

        expect($file->isServerPack)->toBeFalse();
    });

    it('has no address when the author keeps the file on CurseForge', function (mixed $url): void {
        $file = cfClient(cfHttp(Factory::response(['data' => Fixtures::serverPack(['downloadUrl' => $url])])))->file('123', '4002');

        expect($file->downloadUrl)->toBeNull();
    })->with([[null], [''], [5]]);

    it('has no SHA-1 when the source gives none, or gives one that is not a SHA-1', function (mixed $hashes): void {
        $file = cfClient(cfHttp(Factory::response(['data' => Fixtures::serverPack(['hashes' => $hashes])])))->file('123', '4002');

        expect($file->sha1)->toBeNull();
    })->with([
        'none' => [[]],
        'only md5' => [[['value' => md5('x'), 'algo' => 2]]],
        'short' => [[['value' => 'abc', 'algo' => 1]]],
        'not hex' => [[['value' => str_repeat('z', 40), 'algo' => 1]]],
        'not a list' => ['x'],
    ]);

    it('is null for a file that is not there, or no longer available', function (): void {
        expect(cfClient(cfHttp(Factory::response(['error' => 'x'], 404)))->file('123', '9'))->toBeNull()
            ->and(cfClient(cfHttp(Factory::response(['data' => Fixtures::serverPack(['isAvailable' => false])])))->file('123', '4002'))->toBeNull();
    });

    it('is unavailable for any other failure, and for an answer about another file', function (int $status): void {
        expect(fn () => cfClient(cfHttp(Factory::response([], $status)))->file('123', '4002'))->toThrow(ModpackSourceException::class);
    })->with([401, 403, 429, 500, 503]);

    it('does not take an answer about a different file for the one asked', function (): void {
        expect(fn () => cfClient(cfHttp(Factory::response(['data' => Fixtures::serverPack(['id' => 9999])])))->file('123', '4002'))->toThrow(ModpackSourceException::class);
    });

    it('is unavailable for an answer of the wrong shape', function (mixed $body): void {
        expect(fn () => cfClient(cfHttp(Factory::response($body)))->file('123', '4002'))->toThrow(ModpackSourceException::class);
    })->with([
        'no data' => [[]],
        'data is text' => [['data' => 'x']],
        'no file name' => [['data' => ['id' => 4002]]],
    ]);

    it('is unavailable when the source cannot be reached', function (): void {
        expect(fn () => cfClient(cfHttp(fn () => throw new ConnectionException('down')))->file('123', '4002'))->toThrow(ModpackSourceException::class);
    });

    it('never builds a URL from an id that is not a number, and asks nothing', function (string $project, string $file): void {
        $http = cfHttp(Factory::response(['data' => Fixtures::serverPack()]));

        expect(fn () => cfClient($http)->file($project, $file))->toThrow(ModpackSourceException::class);
        $http->assertNothingSent();
    })->with([['../x', '1'], ['1', '1/../2'], ['1?x=y', '1'], ['', '1'], ['1', ''], ["1\n", '1'], ['1', '99999999999']]);
});
