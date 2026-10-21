<?php

declare(strict_types=1);

use FileTransfer\Jobs\FetchRemoteFile;
use FileTransfer\Support\ChunkStore;
use FileTransfer\Support\FileTransferSettings;
use FileTransfer\Support\RemoteFetcher;
use FileTransfer\Support\TransferException;
use FileTransfer\Support\WingsFileService;
use FileTransfer\Tests\ExtensionTestCase;
use GuzzleHttp\Exception\ConnectException;
use GuzzleHttp\Psr7\Request;
use Illuminate\Contracts\Events\Dispatcher;
use Illuminate\Contracts\Queue\Job;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;
use Illuminate\Log\Events\MessageLogged;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Http;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Extensions\ExtensionJobProgress;

uses(ExtensionTestCase::class);

const FT_PUBLIC = ['93.184.216.34'];

/** A job for a fresh progress record, as the controller would have queued it. @return array{0: FetchRemoteFile, 1: string} */
function ftJob(Server $server, string $url = 'https://example.com/pack.zip'): array
{
    $record = app(ExtensionJobProgress::class)->begin('file-transfer', User::factory()->create(), $server, 'ext.file-transfer.remote-fetch');

    return [new FetchRemoteFile($server->uuid, $url, 'mods', 'pack.zip', $record->id), $record->id];
}

/** Runs the job once. Hosts resolve to a public address unless $lookup says otherwise. */
function ftRun(FetchRemoteFile $job, ?Closure $lookup = null, ?Factory $http = null): void
{
    $job->handle(
        app(ExtensionJobProgress::class),
        app(FileTransferSettings::class),
        app(ChunkStore::class),
        new RemoteFetcher($http ?? app(Factory::class), $lookup ?? static fn (): array => FT_PUBLIC),
        app(WingsFileService::class),
    );
}

/** Makes the queue say this is the last attempt, so a failure that could be retried is reported instead. */
function ftLastAttempt(FetchRemoteFile $job): FetchRemoteFile
{
    $queued = Mockery::mock(Job::class);
    $queued->shouldReceive('attempts')->andReturn($job->tries);
    $job->setJob($queued);

    return $job;
}

function ftSnapshot(string $id): object
{
    return app(ExtensionJobProgress::class)->find('file-transfer', $id);
}

/** @return array{0: string, 1: string} status and message of a record: for a failure, "failed" and its code */
function ftOutcome(string $id): array
{
    $snapshot = ftSnapshot($id);

    return [$snapshot->status, $snapshot->message];
}

test('the file is downloaded, handed to the server and the record says so (AC-FT10)', function (): void {
    Http::fake(['example.com/*' => Http::response('hello world', 200, ['Content-Length' => '11'])]);
    [, $server] = $this->generateTestAccount();
    [$job, $id] = ftJob($server);

    ftRun($job);

    expect($this->wings->uploads)->toBe([['server' => $server->uuid, 'path' => '/mods/pack.zip', 'content' => 'hello world']])
        ->and(ftSnapshot($id)->status)->toBe('completed')
        ->and(ftSnapshot($id)->percent)->toBe(100)
        ->and(ftSnapshot($id)->message)->toBe('File transferred successfully.');
});

test('progress goes from downloading at 0 to uploading at 80 to completed at 100 (AC-FT10, FR-FT12)', function (): void {
    [, $server] = $this->generateTestAccount();
    [$job, $id] = ftJob($server);
    $seen = [];
    Http::fake(['example.com/*' => function () use ($id, &$seen) {
        $seen['download'] = [ftSnapshot($id)->percent, ftSnapshot($id)->message];

        return Http::response('hello world', 200, ['Content-Length' => '11']);
    }]);
    $this->wings->onUpload = function () use ($id, &$seen): void {
        $seen['upload'] = [ftSnapshot($id)->percent, ftSnapshot($id)->message, ftSnapshot($id)->status];
    };

    ftRun($job);

    expect($seen['download'])->toBe([0, 'Downloading from remote URL...'])
        ->and($seen['upload'])->toBe([80, 'Uploading to server...', 'running']);
});

test('the temporary download is removed after a success (NFR-FT5)', function (): void {
    Http::fake(['example.com/*' => Http::response('hello world', 200)]);
    [, $server] = $this->generateTestAccount();
    [$job, $id] = ftJob($server);

    ftRun($job);

    expect(is_dir($this->storeRoot.'/tmp/'.$id))->toBeFalse();
});

describe('what the remote server says', function (): void {
    test('"not found" is download_failed and is not retried (AC-FT11, FR-FT19)', function (): void {
        Http::fake(['example.com/*' => Http::response('nope', 404)]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job);

        expect(ftOutcome($id))->toBe(['failed', 'download_failed'])
            ->and($this->wings->uploads)->toBe([]);
    });

    test('a server error is retried, and reported on the last attempt', function (): void {
        Http::fake(['example.com/*' => Http::response('boom', 503)]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        expect(fn () => ftRun($job))->toThrow(TransferException::class)
            ->and(ftSnapshot($id)->status)->toBe('running');

        ftRun(ftLastAttempt($job));
        expect(ftOutcome($id))->toBe(['failed', 'download_failed']);
    });

    test('a Content-Length over the limit fails with download_too_large before the body is read (AC-FT12, FR-FT11)', function (): void {
        $this->configure(['max_remote_mb' => 1]);
        Http::fake(['example.com/*' => Http::response('tiny', 200, ['Content-Length' => (string) (2 * 1048576)])]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job);

        expect(ftOutcome($id))->toBe(['failed', 'download_too_large'])
            ->and($this->wings->uploads)->toBe([]);
    });

    test('with no Content-Length the download is counted and stopped at the limit (EC-FT7)', function (): void {
        $this->configure(['max_remote_mb' => 1]);
        Http::fake(['example.com/*' => Http::response(str_repeat('a', 2 * 1048576), 200)]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job);

        expect(ftOutcome($id))->toBe(['failed', 'download_too_large'])
            ->and($this->wings->uploads)->toBe([])
            ->and(is_dir($this->storeRoot.'/tmp/'.$id))->toBeFalse();
    });

    test('a file exactly at the limit is accepted', function (): void {
        $this->configure(['max_remote_mb' => 1]);
        Http::fake(['example.com/*' => Http::response(str_repeat('a', 1048576), 200)]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job);

        expect(ftSnapshot($id)->status)->toBe('completed');
    });

    test('an empty file is transferred as an empty file', function (): void {
        Http::fake(['example.com/*' => Http::response('', 200)]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job);

        expect($this->wings->uploads[0]['content'])->toBe('')
            ->and(ftSnapshot($id)->status)->toBe('completed');
    });
});

describe('the connection', function (): void {
    test('a timeout is retried, then reported as timeout (EC-FT8)', function (): void {
        Http::fake(['example.com/*' => fn () => throw new ConnectionException('cURL error 28', 0, new ConnectException('timed out', new Request('GET', 'x'), null, ['errno' => 28]))]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        expect(fn () => ftRun($job))->toThrow(TransferException::class, 'timeout');

        ftRun(ftLastAttempt($job));
        expect(ftOutcome($id))->toBe(['failed', 'timeout'])
            ->and(is_dir($this->storeRoot.'/tmp/'.$id))->toBeFalse();
    });

    test('a refused connection is connection_refused', function (): void {
        Http::fake(['example.com/*' => fn () => throw new ConnectionException('cURL error 7', 0, new ConnectException('refused', new Request('GET', 'x'), null, ['errno' => 7]))]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun(ftLastAttempt($job));

        expect(ftOutcome($id))->toBe(['failed', 'connection_refused']);
    });

    test('any other connection error is download_failed', function (): void {
        Http::fake(['example.com/*' => fn () => throw new ConnectionException('something else')]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun(ftLastAttempt($job));

        expect(ftOutcome($id))->toBe(['failed', 'download_failed']);
    });
});

describe('DNS (AC-FT20, T-FT2)', function (): void {
    test('a name that resolves to a private address fails with invalid_url and no request is made', function (string $address): void {
        Http::fake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server, 'https://rebind.example.com/pack.zip');

        ftRun($job, static fn (): array => [$address]);

        expect(ftOutcome($id))->toBe(['failed', 'invalid_url']);
        Http::assertNothingSent();
    })->with(['loopback' => '127.0.0.1', 'private' => '10.1.2.3', 'metadata' => '169.254.169.254', 'IPv6 loopback' => '::1', 'IPv4-mapped' => '::ffff:127.0.0.1']);

    test('one private address among public ones is enough to refuse', function (): void {
        Http::fake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job, static fn (): array => ['93.184.216.34', '10.0.0.5']);

        expect(ftOutcome($id))->toBe(['failed', 'invalid_url']);
        Http::assertNothingSent();
    });

    test('a name that does not resolve is retried, then download_failed', function (): void {
        Http::fake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        expect(fn () => ftRun($job, static fn (): array => []))->toThrow(TransferException::class);

        ftRun(ftLastAttempt($job), static fn (): array => []);
        expect(ftOutcome($id))->toBe(['failed', 'download_failed']);
        Http::assertNothingSent();
    });

    test('the connection is pinned to the address that was checked, so a second DNS answer cannot change it', function (): void {
        $recorder = new class (app(Dispatcher::class)) extends Factory
        {
            /** @var array<string, mixed> */
            public array $options = [];

            public function __call($method, $parameters)
            {
                if ($method === 'withOptions') {
                    $this->options = $parameters[0];
                }

                return parent::__call($method, $parameters);
            }
        };
        $recorder->fake(['example.com:8080/*' => Http::response('hi', 200)]);
        [, $server] = $this->generateTestAccount();
        [$job] = ftJob($server, 'http://example.com:8080/pack.zip');

        ftRun($job, static fn (): array => ['93.184.216.34'], $recorder);

        expect($recorder->options['curl'][CURLOPT_RESOLVE])->toBe(['example.com:8080:93.184.216.34'])
            ->and($recorder->options['stream'])->toBeTrue();
    });

    test('an IPv6 address is pinned in brackets', function (): void {
        $recorder = new class (app(Dispatcher::class)) extends Factory
        {
            /** @var array<string, mixed> */
            public array $options = [];

            public function __call($method, $parameters)
            {
                if ($method === 'withOptions') {
                    $this->options = $parameters[0];
                }

                return parent::__call($method, $parameters);
            }
        };
        $recorder->fake(['example.com/*' => Http::response('hi', 200)]);
        [, $server] = $this->generateTestAccount();
        [$job] = ftJob($server);

        ftRun($job, static fn (): array => ['2606:2800:220:1:248:1893:25c8:1946'], $recorder);

        expect($recorder->options['curl'][CURLOPT_RESOLVE])->toBe(['example.com:443:[2606:2800:220:1:248:1893:25c8:1946]']);
    });
});

describe('redirects (EC-FT6)', function (): void {
    test('a redirect to an https address that is public is followed', function (): void {
        Http::fake([
            'example.com/*' => Http::response('', 302, ['Location' => 'https://cdn.example.org/real.zip']),
            'cdn.example.org/*' => Http::response('the file', 200),
        ]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job);

        expect($this->wings->uploads[0]['content'])->toBe('the file')
            ->and(ftSnapshot($id)->status)->toBe('completed');
    });

    test('a relative redirect stays on the same host', function (string $location, string $expectedUrl): void {
        Http::fake([
            'https://example.com/start/pack.zip' => Http::response('', 301, ['Location' => $location]),
            $expectedUrl => Http::response('moved', 200),
        ]);
        [, $server] = $this->generateTestAccount();
        [$job] = ftJob($server, 'https://example.com/start/pack.zip');

        ftRun($job);

        expect($this->wings->uploads[0]['content'])->toBe('moved');
    })->with([
        'an absolute path' => ['/other/pack.zip', 'https://example.com/other/pack.zip'],
        'a relative path' => ['next.zip', 'https://example.com/start/next.zip'],
        'a protocol-relative one' => ['//cdn.example.org/pack.zip', 'https://cdn.example.org/pack.zip'],
    ]);

    test('a redirect to a name that resolves to a private address fails with invalid_url, after one request', function (): void {
        Http::fake(['example.com/*' => Http::response('', 302, ['Location' => 'https://internal.example.org/secret'])]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job, static fn (string $host): array => $host === 'internal.example.org' ? ['10.0.0.5'] : FT_PUBLIC);

        expect(ftOutcome($id))->toBe(['failed', 'invalid_url']);
        Http::assertSentCount(1);
    });

    test('a redirect to a private address written out is refused too', function (string $target): void {
        Http::fake(['example.com/*' => Http::response('', 302, ['Location' => $target])]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job);

        expect(ftOutcome($id))->toBe(['failed', 'invalid_url']);
        Http::assertSentCount(1);
    })->with(['https://169.254.169.254/latest/meta-data/', 'https://[::1]/', 'https://localhost/']);

    test('a redirect to plain http is refused: only https is followed (FR-FT10)', function (): void {
        Http::fake(['example.com/*' => Http::response('', 302, ['Location' => 'http://cdn.example.org/real.zip'])]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job);

        expect(ftOutcome($id))->toBe(['failed', 'invalid_url']);
        Http::assertSentCount(1);
    });

    test('more than three redirects is download_failed', function (): void {
        Http::fake(['example.com/*' => Http::response('', 302, ['Location' => 'https://example.com/again'])]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job);

        expect(ftOutcome($id))->toBe(['failed', 'download_failed']);
        Http::assertSentCount(4);
    });

    test('a redirect without a Location is download_failed', function (): void {
        Http::fake(['example.com/*' => Http::response('', 302)]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);

        ftRun($job);

        expect(ftOutcome($id))->toBe(['failed', 'download_failed']);
    });
});

describe('Wings (EC-FT9)', function (): void {
    test('a refusal is upload_failed after the retries, and the temporary file is gone', function (): void {
        Http::fake(['example.com/*' => Http::response('data', 200)]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);
        $this->wings->failWith = new TransferException('upload_failed', true);

        expect(fn () => ftRun($job))->toThrow(TransferException::class)
            ->and(is_dir($this->storeRoot.'/tmp/'.$id))->toBeFalse();

        ftRun(ftLastAttempt($job));
        expect(ftOutcome($id))->toBe(['failed', 'upload_failed']);
    });

    test('an error nobody expected is reported as download_failed, not as a crash', function (): void {
        Http::fake(['example.com/*' => Http::response('data', 200)]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = ftJob($server);
        app()->instance(WingsFileService::class, new class implements WingsFileService
        {
            public function upload(string $serverUuid, string $localFilePath, string $remotePath): void
            {
                throw new LogicException('a bug');
            }
        });

        ftRun($job);

        expect(ftOutcome($id))->toBe(['failed', 'download_failed']);
    });
});

test('a record that has expired is left alone instead of failing the job', function (): void {
    Http::fake(['example.com/*' => Http::response('data', 200)]);
    [, $server] = $this->generateTestAccount();
    $job = new FetchRemoteFile($server->uuid, 'https://example.com/pack.zip', 'mods', 'pack.zip', '11111111-2222-4333-8444-555555555555');

    ftRun($job);

    expect($this->wings->uploads)->toHaveCount(1);
});

test('a job the queue gave up on tells the browser it failed', function (): void {
    [, $server] = $this->generateTestAccount();
    [$job, $id] = ftJob($server);

    $job->failed(new RuntimeException('worker died'));

    expect(ftOutcome($id))->toBe(['failed', 'timeout']);
});

test('logs never hold the URL, its token or the file name (NFR-FT8)', function (): void {
    $logged = [];
    Event::listen(MessageLogged::class, function (MessageLogged $event) use (&$logged): void {
        $logged[] = $event->message.' '.json_encode($event->context);
    });
    Http::fake(['example.com/*' => Http::response('nope', 404)]);
    [, $server] = $this->generateTestAccount();
    [$job] = ftJob($server, 'https://example.com/pack.zip?token=SECRET-TOKEN-123');

    ftRun($job);

    $text = implode("\n", $logged);
    // Without this the checks below would pass for the wrong reason: the listener has to have seen the entry.
    expect($text)->toContain('file-transfer: remote fetch failed')
        ->and($text)->not->toContain('SECRET-TOKEN-123')
        ->and($text)->not->toContain('example.com')
        ->and($text)->not->toContain('pack.zip');
});

test('the job is unique per server and progress record, and backs off between tries', function (): void {
    [, $server] = $this->generateTestAccount();
    [$job, $id] = ftJob($server);

    expect($job->uniqueId())->toBe("ftr-{$server->uuid}-{$id}")
        ->and($job->backoff())->toBe([10, 30])
        ->and($job->tries)->toBe(3)
        ->and($job->uniqueFor)->toBe(1800);
});
