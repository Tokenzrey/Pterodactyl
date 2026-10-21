<?php

declare(strict_types=1);

use FileTransfer\Support\PanelWingsFileService;
use FileTransfer\Support\TransferException;
use FileTransfer\Tests\ExtensionTestCase;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;

uses(ExtensionTestCase::class);

/** A local file with this content, removed when the test ends. */
function ftLocalFile(string $content): string
{
    $path = tempnam(sys_get_temp_dir(), 'ft-local-');
    file_put_contents($path, $content);
    register_shutdown_function(static fn () => @unlink($path));

    return $path;
}

/**
 * Fakes Wings and keeps what it was sent. The request is read inside the fake: its body is a stream of the local
 * file, which the service closes as soon as it is done, so it cannot be read again afterwards.
 *
 * @param  list<array{method: string, url: string, authorization: string, body: string}>  $sent
 */
function ftFakeWings(array &$sent, int $status = 204): void
{
    Http::fake(['*' => function (Request $request) use (&$sent, $status) {
        $sent[] = ['method' => $request->method(), 'url' => $request->url(), 'authorization' => $request->header('Authorization')[0] ?? '', 'body' => $request->body()];

        return Http::response($status === 204 ? '' : 'no space left', $status);
    }]);
}

test('the file is written through the Panel\'s authenticated connection to the server\'s node', function (): void {
    $sent = [];
    ftFakeWings($sent);
    [, $server] = $this->generateTestAccount();

    (new PanelWingsFileService())->upload($server->uuid, ftLocalFile('the file bytes'), '/mods/pack.zip');

    expect($sent)->toHaveCount(1)
        ->and($sent[0]['method'])->toBe('POST')
        ->and($sent[0]['url'])->toStartWith($server->node->getConnectionAddress())
        ->and($sent[0]['url'])->toContain("/api/servers/{$server->uuid}/files/write")
        ->and(parse_url($sent[0]['url'], PHP_URL_QUERY))->toBe('file=%2Fmods%2Fpack.zip')
        ->and($sent[0]['authorization'])->toStartWith('Bearer ')
        ->and($sent[0]['body'])->toBe('the file bytes');
});

test('an empty file is written as an empty body', function (): void {
    $sent = [];
    ftFakeWings($sent);
    [, $server] = $this->generateTestAccount();

    (new PanelWingsFileService())->upload($server->uuid, ftLocalFile(''), '/empty.txt');

    expect($sent[0]['body'])->toBe('');
});

test('a file with every byte value arrives unchanged, so binary uploads are not corrupted', function (): void {
    $sent = [];
    ftFakeWings($sent);
    [, $server] = $this->generateTestAccount();
    $binary = implode('', array_map('chr', range(0, 255))).random_bytes(70000);

    (new PanelWingsFileService())->upload($server->uuid, ftLocalFile($binary), '/data.bin');

    expect($sent[0]['body'])->toBe($binary);
});

test('a refusal from Wings is upload_failed, may be retried, and says nothing of what Wings answered', function (int $status): void {
    $sent = [];
    ftFakeWings($sent, $status);
    [, $server] = $this->generateTestAccount();

    try {
        (new PanelWingsFileService())->upload($server->uuid, ftLocalFile('x'), '/a.zip');
        $failure = null;
    } catch (TransferException $exception) {
        $failure = $exception;
    }

    expect($failure?->reason)->toBe('upload_failed')
        ->and($failure?->retryable)->toBeTrue()
        ->and($failure?->getMessage())->not->toContain('no space');
})->with([500, 502, 404, 422]);

test('a node that cannot be reached is upload_failed', function (): void {
    Http::fake(['*' => fn () => throw new ConnectionException('node is down')]);
    [, $server] = $this->generateTestAccount();

    expect(fn () => (new PanelWingsFileService())->upload($server->uuid, ftLocalFile('x'), '/a.zip'))->toThrow(TransferException::class, 'upload_failed');
});

test('a server that does not exist, and a local file that does not exist, are upload_failed', function (): void {
    Http::fake();
    [, $server] = $this->generateTestAccount();

    expect(fn () => (new PanelWingsFileService())->upload('99999999-2222-4333-8444-555555555555', ftLocalFile('x'), '/a.zip'))->toThrow(TransferException::class, 'upload_failed')
        ->and(fn () => (new PanelWingsFileService())->upload($server->uuid, '/no/such/file', '/a.zip'))->toThrow(TransferException::class, 'upload_failed');

    Http::assertNothingSent();
});
