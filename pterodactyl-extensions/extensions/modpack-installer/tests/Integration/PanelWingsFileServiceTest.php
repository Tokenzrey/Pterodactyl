<?php

declare(strict_types=1);

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;
use ModpackInstaller\Support\PanelWingsFileService;
use ModpackInstaller\Support\WingsException;
use ModpackInstaller\Tests\ExtensionTestCase;

uses(ExtensionTestCase::class);

/** A local file with this content, removed when the test ends. */
function pwLocalFile(string $content = ''): string
{
    $path = tempnam(sys_get_temp_dir(), 'mki-local-');
    file_put_contents($path, $content);
    register_shutdown_function(static fn () => @unlink($path));

    return $path;
}

/**
 * Fakes the node and keeps every request it received. The body is read inside the fake: an upload's body is a stream
 * of the local file, which the service closes as soon as it is done.
 *
 * @param  list<array{method: string, path: string, query: string, authorization: string, json: mixed, body: string}>  $sent
 */
function pwFakeNode(array &$sent, callable $answer): void
{
    Http::fake(['*' => function (Request $request) use (&$sent, $answer) {
        $sent[] = [
            'method' => $request->method(),
            'path' => (string) parse_url($request->url(), PHP_URL_PATH),
            'query' => (string) parse_url($request->url(), PHP_URL_QUERY),
            'authorization' => $request->header('Authorization')[0] ?? '',
            'json' => json_decode($request->body(), true),
            'body' => $request->body(),
        ];

        return $answer($request);
    }]);
}

it('writes the archive through the Panel\'s authenticated connection to the server\'s node', function (): void {
    $sent = [];
    pwFakeNode($sent, fn () => Http::response('', 204));
    [, $server] = $this->generateTestAccount();

    (new PanelWingsFileService())->upload($server->uuid, pwLocalFile('the archive bytes'), '/packs/atm9/modpack.zip');

    expect($sent)->toHaveCount(1)
        ->and($sent[0]['method'])->toBe('POST')
        ->and($sent[0]['path'])->toBe("/api/servers/{$server->uuid}/files/write")
        ->and($sent[0]['query'])->toBe('file=%2Fpacks%2Fatm9%2Fmodpack.zip')
        ->and($sent[0]['authorization'])->toStartWith('Bearer ')
        ->and($sent[0]['body'])->toBe('the archive bytes');
});

it('sends an archive with every byte value unchanged, so a binary pack is not corrupted', function (): void {
    $bytes = implode('', array_map('chr', range(0, 255))).random_bytes(90000);
    $sent = [];
    pwFakeNode($sent, fn () => Http::response('', 204));
    [, $server] = $this->generateTestAccount();

    (new PanelWingsFileService())->upload($server->uuid, pwLocalFile($bytes), '/modpack.zip');

    expect($sent[0]['body'])->toBe($bytes);
});

it('asks Wings to extract an archive in the folder it is in', function (): void {
    $sent = [];
    pwFakeNode($sent, fn () => Http::response('', 204));
    [, $server] = $this->generateTestAccount();

    (new PanelWingsFileService())->decompress($server->uuid, '/packs/atm9/modpack.zip');

    expect($sent[0]['path'])->toBe("/api/servers/{$server->uuid}/files/decompress")
        ->and($sent[0]['json'])->toBe(['root' => '/packs/atm9', 'file' => 'modpack.zip']);
});

it('extracts an archive in the root as root "/"', function (): void {
    $sent = [];
    pwFakeNode($sent, fn () => Http::response('', 204));
    [, $server] = $this->generateTestAccount();

    (new PanelWingsFileService())->decompress($server->uuid, '/modpack.zip');

    expect($sent[0]['json'])->toBe(['root' => '/', 'file' => 'modpack.zip']);
});

it('lists the entries of a folder by name', function (): void {
    $sent = [];
    pwFakeNode($sent, fn () => Http::response([['name' => 'world', 'directory' => true], ['name' => 'start.sh', 'directory' => false]]));
    [, $server] = $this->generateTestAccount();

    $names = (new PanelWingsFileService())->listFiles($server->uuid, '/packs/atm9');

    expect($names)->toBe(['world', 'start.sh'])
        ->and($sent[0]['method'])->toBe('GET')
        ->and($sent[0]['path'])->toBe("/api/servers/{$server->uuid}/files/list-directory")
        ->and($sent[0]['query'])->toBe('directory=%2Fpacks%2Fatm9');
});

it('ignores entries that carry no usable name', function (): void {
    $sent = [];
    pwFakeNode($sent, fn () => Http::response([['name' => 'ok'], ['size' => 3], 'text', ['name' => 7]]));
    [, $server] = $this->generateTestAccount();

    expect((new PanelWingsFileService())->listFiles($server->uuid, '/'))->toBe(['ok']);
});

it('refuses an answer that is not a list', function (): void {
    $sent = [];
    pwFakeNode($sent, fn () => Http::response('not a list'));
    [, $server] = $this->generateTestAccount();

    expect(fn () => (new PanelWingsFileService())->listFiles($server->uuid, '/'))->toThrow(WingsException::class, 'list_failed');
});

it('deletes one file by its folder and name', function (): void {
    $sent = [];
    pwFakeNode($sent, fn () => Http::response('', 204));
    [, $server] = $this->generateTestAccount();

    (new PanelWingsFileService())->deleteFile($server->uuid, '/packs/atm9/start.sh');

    expect($sent[0]['path'])->toBe("/api/servers/{$server->uuid}/files/delete")
        ->and($sent[0]['json'])->toBe(['root' => '/packs/atm9', 'files' => ['start.sh']]);
});

it('refuses a path that is relative, climbs out, or has odd characters, before asking the node anything', function (string $path): void {
    $sent = [];
    pwFakeNode($sent, fn () => Http::response('', 204));
    [, $server] = $this->generateTestAccount();
    $service = new PanelWingsFileService();

    expect(fn () => $service->deleteFile($server->uuid, $path))->toThrow(WingsException::class, 'invalid_path')
        ->and(fn () => $service->decompress($server->uuid, $path))->toThrow(WingsException::class, 'invalid_path')
        ->and(fn () => $service->listFiles($server->uuid, $path))->toThrow(WingsException::class, 'invalid_path')
        ->and(fn () => $service->upload($server->uuid, pwLocalFile('x'), $path))->toThrow(WingsException::class, 'invalid_path')
        ->and($sent)->toBe([]);
})->with(['relative/file.zip', '/a/../b.zip', '/a//b.zip', '/a/./b.zip', '/a;rm.zip', '/café.zip', '', "/a\n"]);

it('reports an answer of Wings that refuses as not unreachable, and does not repeat what Wings said', function (int $status): void {
    $sent = [];
    pwFakeNode($sent, fn () => Http::response('no space left on device at /var/lib', $status));
    [, $server] = $this->generateTestAccount();

    try {
        (new PanelWingsFileService())->upload($server->uuid, pwLocalFile('x'), '/a.zip');
        $failure = null;
    } catch (WingsException $exception) {
        $failure = $exception;
    }

    expect($failure?->getMessage())->toBe('upload_failed')
        ->and($failure?->unreachable)->toBeFalse();
})->with([500, 502, 404, 422]);

it('names the step that failed', function (string $method, string $reason): void {
    $sent = [];
    pwFakeNode($sent, fn () => Http::response('', 500));
    [, $server] = $this->generateTestAccount();

    $call = match ($method) {
        'decompress' => fn () => (new PanelWingsFileService())->decompress($server->uuid, '/a.zip'),
        'list' => fn () => (new PanelWingsFileService())->listFiles($server->uuid, '/'),
        'delete' => fn () => (new PanelWingsFileService())->deleteFile($server->uuid, '/a.zip'),
    };

    expect($call)->toThrow(WingsException::class, $reason);
})->with([['decompress', 'extract_failed'], ['list', 'list_failed'], ['delete', 'delete_failed']]);

it('reports a node that cannot be reached as unreachable, the one failure worth another try', function (): void {
    Http::fake(['*' => fn () => throw new ConnectionException('node is down')]);
    [, $server] = $this->generateTestAccount();

    try {
        (new PanelWingsFileService())->decompress($server->uuid, '/a.zip');
        $failure = null;
    } catch (WingsException $exception) {
        $failure = $exception;
    }

    expect($failure?->unreachable)->toBeTrue();
});

it('reports a server that does not exist without asking any node', function (): void {
    Http::fake();

    expect(fn () => (new PanelWingsFileService())->deleteFile('99999999-2222-4333-8444-555555555555', '/a.zip'))->toThrow(WingsException::class, 'server_not_found');

    Http::assertNothingSent();
});

it('reports a local file that does not exist as upload_failed, before asking any node', function (): void {
    Http::fake();
    [, $server] = $this->generateTestAccount();

    expect(fn () => (new PanelWingsFileService())->upload($server->uuid, '/no/such/file', '/a.zip'))->toThrow(WingsException::class, 'upload_failed');

    Http::assertNothingSent();
});
