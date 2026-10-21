<?php

declare(strict_types=1);

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;
use MultiNodeSync\Support\PanelWingsFileService;
use MultiNodeSync\Support\WingsException;
use MultiNodeSync\Tests\ExtensionTestCase;

uses(ExtensionTestCase::class);

/** A local file with this content, removed when the test ends. */
function mnsLocalFile(string $content = ''): string
{
    $path = tempnam(sys_get_temp_dir(), 'mns-local-');
    file_put_contents($path, $content);
    register_shutdown_function(static fn () => @unlink($path));

    return $path;
}

/**
 * Fakes the node and keeps every request it received. The body is read inside the fake: an upload's body is a stream
 * of the local file, which the service closes as soon as it is done.
 *
 * @param  list<array{method: string, path: string, query: string, authorization: string, json: mixed, body: string}>  $sent
 * @param  callable(Request): mixed  $answer  returns an Http::response() for a request
 */
function mnsFakeNode(array &$sent, callable $answer): void
{
    Http::fake(['*' => function (Request $request) use (&$sent, $answer) {
        $sent[] = [
            'method' => $request->method(),
            'path' => parse_url($request->url(), PHP_URL_PATH),
            'query' => (string) parse_url($request->url(), PHP_URL_QUERY),
            'authorization' => $request->header('Authorization')[0] ?? '',
            'json' => json_decode($request->body(), true),
            'body' => $request->body(),
        ];

        return $answer($request);
    }]);
}

it('lists the entries of a folder through the Panel\'s authenticated connection to the node', function (): void {
    $sent = [];
    mnsFakeNode($sent, fn () => Http::response([['name' => 'world', 'is_file' => false], ['name' => 'server.properties', 'is_file' => true]]));
    [, $server] = $this->generateTestAccount();

    $names = (new PanelWingsFileService())->listFiles($server->uuid, '/');

    expect($names)->toBe(['world', 'server.properties'])
        ->and($sent[0]['method'])->toBe('GET')
        ->and($sent[0]['path'])->toBe("/api/servers/{$server->uuid}/files/list-directory")
        ->and($sent[0]['query'])->toBe('directory=%2F')
        ->and($sent[0]['authorization'])->toStartWith('Bearer ');
});

it('ignores entries that carry no usable name', function (): void {
    $sent = [];
    mnsFakeNode($sent, fn () => Http::response([['name' => 'ok'], ['size' => 3], 'text', ['name' => 7]]));
    [, $server] = $this->generateTestAccount();

    expect((new PanelWingsFileService())->listFiles($server->uuid, '/'))->toBe(['ok']);
});

it('packs every top-level entry into one archive and returns its path', function (): void {
    $sent = [];
    mnsFakeNode($sent, function (Request $request) {
        if (str_ends_with($request->url(), '/files/list-directory?directory=%2F')) {
            return Http::response([['name' => 'world'], ['name' => 'server.properties']]);
        }

        return Http::response(['name' => 'archive-1.tar.gz', 'size' => 10]);
    });
    [, $server] = $this->generateTestAccount();

    $archive = (new PanelWingsFileService())->archive($server->uuid);

    expect($archive)->toBe('/archive-1.tar.gz')
        ->and($sent[1]['path'])->toBe("/api/servers/{$server->uuid}/files/compress")
        ->and($sent[1]['json'])->toBe(['root' => '/', 'files' => ['world', 'server.properties']]);
});

it('refuses to archive an empty server, and an answer whose name is not a plain file name', function (mixed $answer): void {
    $sent = [];
    mnsFakeNode($sent, fn (Request $request) => str_ends_with($request->url(), 'list-directory?directory=%2F') ? Http::response([['name' => 'world']]) : Http::response($answer));
    [, $server] = $this->generateTestAccount();

    expect(fn () => (new PanelWingsFileService())->archive($server->uuid))->toThrow(WingsException::class, 'archive_failed');
})->with([[['name' => '../etc/passwd']], [['name' => "a\nb"]], [['size' => 1]], ['text']]);

it('archives nothing from an empty server', function (): void {
    $sent = [];
    mnsFakeNode($sent, fn () => Http::response([]));
    [, $server] = $this->generateTestAccount();

    expect(fn () => (new PanelWingsFileService())->archive($server->uuid))->toThrow(WingsException::class, 'archive_failed');
});

it('streams an archive from the node into a local file, byte for byte', function (): void {
    $bytes = implode('', array_map('chr', range(0, 255))).random_bytes(90000);
    $sent = [];
    mnsFakeNode($sent, fn () => Http::response($bytes));
    [, $server] = $this->generateTestAccount();
    $local = mnsLocalFile();

    (new PanelWingsFileService())->download($server->uuid, '/archive-1.tar.gz', $local);

    expect(file_get_contents($local))->toBe($bytes)
        ->and($sent[0]['method'])->toBe('GET')
        ->and($sent[0]['path'])->toBe("/api/servers/{$server->uuid}/files/contents")
        ->and($sent[0]['query'])->toBe('file=%2Farchive-1.tar.gz');
});

it('streams a local file onto the node, unchanged', function (): void {
    $bytes = implode('', array_map('chr', range(0, 255))).random_bytes(70000);
    $sent = [];
    mnsFakeNode($sent, fn () => Http::response(''));
    [, $server] = $this->generateTestAccount();

    (new PanelWingsFileService())->upload($server->uuid, mnsLocalFile($bytes), '/backups/migration/migration.tar.gz');

    expect($sent[0]['method'])->toBe('POST')
        ->and($sent[0]['path'])->toBe("/api/servers/{$server->uuid}/files/write")
        ->and($sent[0]['query'])->toBe('file=%2Fbackups%2Fmigration%2Fmigration.tar.gz')
        ->and($sent[0]['body'])->toBe($bytes);
});

it('extracts an archive in the folder it is in', function (): void {
    $sent = [];
    mnsFakeNode($sent, fn () => Http::response(''));
    [, $server] = $this->generateTestAccount();

    (new PanelWingsFileService())->decompress($server->uuid, '/backups/migration/migration.tar.gz');

    expect($sent[0]['path'])->toBe("/api/servers/{$server->uuid}/files/decompress")
        ->and($sent[0]['json'])->toBe(['root' => '/backups/migration', 'file' => 'migration.tar.gz']);
});

it('deletes one entry by its folder and name, as Wings expects', function (): void {
    $sent = [];
    mnsFakeNode($sent, fn () => Http::response(''));
    [, $server] = $this->generateTestAccount();

    (new PanelWingsFileService())->deleteFile($server->uuid, '/world');

    expect($sent[0]['path'])->toBe("/api/servers/{$server->uuid}/files/delete")
        ->and($sent[0]['json'])->toBe(['root' => '/', 'files' => ['world']]);
});

it('refuses a path that is relative, climbs out, or has odd characters, before asking the node anything', function (string $path): void {
    $sent = [];
    mnsFakeNode($sent, fn () => Http::response(''));
    [, $server] = $this->generateTestAccount();
    $service = new PanelWingsFileService();

    expect(fn () => $service->deleteFile($server->uuid, $path))->toThrow(WingsException::class, 'invalid_path')
        ->and(fn () => $service->decompress($server->uuid, $path))->toThrow(WingsException::class, 'invalid_path')
        ->and($sent)->toBe([]);
})->with(['relative/file.zip', '/a/../b.zip', '/a//b.zip', '/a/./b.zip', '/a;rm.zip', '/café.zip', '']);

it('reports an answer of Wings that refuses as not unreachable, and does not repeat what Wings said', function (int $status): void {
    $sent = [];
    mnsFakeNode($sent, fn () => Http::response('no space left on device at /var/lib', $status));
    [, $server] = $this->generateTestAccount();

    try {
        (new PanelWingsFileService())->upload($server->uuid, mnsLocalFile('x'), '/a.zip');
        $failure = null;
    } catch (WingsException $exception) {
        $failure = $exception;
    }

    expect($failure?->getMessage())->toBe('upload_failed')
        ->and($failure?->unreachable)->toBeFalse();
})->with([500, 502, 404, 422]);

it('reports a node that cannot be reached as unreachable, so the migration can say which side is down', function (): void {
    Http::fake(['*' => fn () => throw new ConnectionException('node is down')]);
    [, $server] = $this->generateTestAccount();

    try {
        (new PanelWingsFileService())->archive($server->uuid);
        $failure = null;
    } catch (WingsException $exception) {
        $failure = $exception;
    }

    expect($failure?->unreachable)->toBeTrue();
});

it('reports a server that does not exist without asking any node', function (): void {
    Http::fake();

    expect(fn () => (new PanelWingsFileService())->listFiles('99999999-2222-4333-8444-555555555555', '/'))->toThrow(WingsException::class, 'server_not_found');

    Http::assertNothingSent();
});

it('reports a local file that does not exist as upload_failed, before asking any node', function (): void {
    Http::fake();
    [, $server] = $this->generateTestAccount();

    expect(fn () => (new PanelWingsFileService())->upload($server->uuid, '/no/such/file', '/a.zip'))->toThrow(WingsException::class, 'upload_failed');

    Http::assertNothingSent();
});
