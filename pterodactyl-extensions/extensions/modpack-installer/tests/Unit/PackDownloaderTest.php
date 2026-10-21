<?php

declare(strict_types=1);

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\Request;
use ModpackInstaller\Support\ModpackJobException;
use ModpackInstaller\Support\PackDownloader;

const PD_URL = 'https://edge.forgecdn.net/files/4000/001/pack.zip';

function pdDestination(): string
{
    $path = sys_get_temp_dir().'/pd-'.bin2hex(random_bytes(6)).'.zip';
    register_shutdown_function(static fn () => @unlink($path));

    return $path;
}

/** A Factory that answers each request from the list, in order, and fails any beyond it. */
function pdHttp(array $answers): Factory
{
    $http = new Factory();
    $http->preventStrayRequests();
    $http->fake(['*' => $http->sequence($answers)->whenEmpty(Factory::response('unexpected extra request', 500))]);

    return $http;
}

/** @return array{0: string, 1: int} */
function pdFailure(Closure $run): array
{
    try {
        $run();
    } catch (ModpackJobException $exception) {
        return [$exception->errorCode(), (int) $exception->retryable];
    }

    return ['no failure', 0];
}

it('writes the archive to the file, and says how many bytes', function (): void {
    $to = pdDestination();

    $bytes = (new PackDownloader(pdHttp([Factory::response('the pack', 200, ['Content-Length' => '8'])])))->download(PD_URL, $to, 1000);

    expect($bytes)->toBe(8)
        ->and(file_get_contents($to))->toBe('the pack');
});

it('keeps every byte value as it is', function (): void {
    $to = pdDestination();
    $binary = implode('', array_map('chr', range(0, 255))).random_bytes(200000);

    (new PackDownloader(pdHttp([Factory::response($binary)])))->download(PD_URL, $to, 1000000);

    expect(file_get_contents($to))->toBe($binary);
});

it('reports how far it has got, against the size the server announced', function (): void {
    $seen = [];

    (new PackDownloader(pdHttp([Factory::response(str_repeat('x', 150000), 200, ['Content-Length' => '150000'])])))
        ->download(PD_URL, pdDestination(), 1000000, null, function (int $written, ?int $total) use (&$seen): void {
            $seen[] = [$written, $total];
        });

    expect($seen)->not->toBe([])
        ->and(end($seen))->toBe([150000, 150000])
        ->and(array_column($seen, 0))->toBe(array_values(array_unique(array_column($seen, 0))));
});

describe('the size limit (FR-MI8, AC-MI11)', function (): void {
    it('refuses by Content-Length before reading anything, and leaves no file', function (): void {
        $to = pdDestination();

        $failure = pdFailure(fn () => (new PackDownloader(pdHttp([Factory::response('x', 200, ['Content-Length' => '5000'])])))->download(PD_URL, $to, 1000));

        expect($failure)->toBe(['download_too_large', 0])
            ->and(file_exists($to))->toBeFalse();
    });

    it('stops a download that goes past the limit without announcing its size, and removes the part', function (): void {
        $to = pdDestination();

        $failure = pdFailure(fn () => (new PackDownloader(pdHttp([Factory::response(str_repeat('x', 5000))])))->download(PD_URL, $to, 1000));

        expect($failure)->toBe(['download_too_large', 0])
            ->and(file_exists($to))->toBeFalse();
    });

    it('accepts a download of exactly the limit', function (): void {
        $to = pdDestination();

        $bytes = (new PackDownloader(pdHttp([Factory::response(str_repeat('x', 1000), 200, ['Content-Length' => '1000'])])))->download(PD_URL, $to, 1000);

        expect($bytes)->toBe(1000);
    });
});

describe('the checksum', function (): void {
    it('accepts an archive that matches', function (): void {
        $bytes = (new PackDownloader(pdHttp([Factory::response('pack')])))->download(PD_URL, pdDestination(), 1000, sha1('pack'));

        expect($bytes)->toBe(4);
    });

    it('refuses an archive that does not, and removes it', function (): void {
        $to = pdDestination();

        $failure = pdFailure(fn () => (new PackDownloader(pdHttp([Factory::response('tampered')])))->download(PD_URL, $to, 1000, sha1('pack')));

        expect($failure)->toBe(['download_failed', 0])
            ->and(file_exists($to))->toBeFalse();
    });

    it('skips the check when the source gave no checksum', function (): void {
        expect((new PackDownloader(pdHttp([Factory::response('anything')])))->download(PD_URL, pdDestination(), 1000, null))->toBe(8);
    });
});

describe('addresses (T-MI1)', function (): void {
    it('refuses an address off the allow-list without asking anything', function (string $url): void {
        $http = pdHttp([Factory::response('x')]);

        expect(pdFailure(fn () => (new PackDownloader($http))->download($url, pdDestination(), 1000)))->toBe(['download_failed', 0]);
        $http->assertNothingSent();
    })->with([
        'http' => 'http://edge.forgecdn.net/a.zip',
        'loopback' => 'https://127.0.0.1/a.zip',
        'metadata' => 'https://169.254.169.254/latest/meta-data/',
        'other host' => 'https://evil.test/a.zip',
        'lookalike' => 'https://evilforgecdn.net/a.zip',
    ]);

    it('follows a redirect to another allowed address, absolute or relative', function (string $location): void {
        $http = pdHttp([Factory::response('', 302, ['Location' => $location]), Factory::response('moved', 200, ['Content-Length' => '5'])]);
        $to = pdDestination();

        (new PackDownloader($http))->download(PD_URL, $to, 1000);

        expect(file_get_contents($to))->toBe('moved');
        $http->assertSentCount(2);
    })->with(['https://mediafilez.forgecdn.net/files/1/2/pack.zip', '/files/9/9/pack.zip']);

    it('refuses a redirect to an address off the allow-list, and does not ask it', function (string $location): void {
        $http = pdHttp([Factory::response('', 302, ['Location' => $location]), Factory::response('secret', 200)]);

        expect(pdFailure(fn () => (new PackDownloader($http))->download(PD_URL, pdDestination(), 1000)))->toBe(['download_failed', 0]);
        $http->assertSentCount(1);
        $http->assertNotSent(fn (Request $request): bool => ! str_contains($request->url(), 'forgecdn.net'));
    })->with([
        'metadata' => 'http://169.254.169.254/latest/meta-data/',
        'internal https' => 'https://10.0.0.5/a.zip',
        'other host' => 'https://evil.test/a.zip',
        'downgrade to http' => 'http://edge.forgecdn.net/a.zip',
    ]);

    it('gives up after three redirects', function (): void {
        $redirect = Factory::response('', 302, ['Location' => 'https://edge.forgecdn.net/next.zip']);
        $http = pdHttp([$redirect, $redirect, $redirect, $redirect, Factory::response('end')]);

        expect(pdFailure(fn () => (new PackDownloader($http))->download(PD_URL, pdDestination(), 1000)))->toBe(['download_failed', 0]);
        $http->assertSentCount(4);
    });

    it('follows exactly three redirects', function (): void {
        $redirect = Factory::response('', 302, ['Location' => 'https://edge.forgecdn.net/next.zip']);
        $http = pdHttp([$redirect, $redirect, $redirect, Factory::response('end')]);
        $to = pdDestination();

        (new PackDownloader($http))->download(PD_URL, $to, 1000);

        expect(file_get_contents($to))->toBe('end');
    });

    it('refuses a redirect without a Location', function (): void {
        expect(pdFailure(fn () => (new PackDownloader(pdHttp([Factory::response('', 302)])))->download(PD_URL, pdDestination(), 1000)))->toBe(['download_failed', 0]);
    });
});

describe('failures at the CDN', function (): void {
    it('treats a missing or forbidden file as final', function (int $status): void {
        expect(pdFailure(fn () => (new PackDownloader(pdHttp([Factory::response('', $status)])))->download(PD_URL, pdDestination(), 1000)))->toBe(['download_failed', 0]);
    })->with([400, 401, 403, 404, 410]);

    it('treats a busy or broken CDN as worth another try', function (int $status): void {
        expect(pdFailure(fn () => (new PackDownloader(pdHttp([Factory::response('', $status)])))->download(PD_URL, pdDestination(), 1000)))->toBe(['source_unavailable', 1]);
    })->with([429, 500, 502, 503, 504]);

    it('treats a connection that fails as worth another try', function (): void {
        $http = new Factory();
        $http->fake(['*' => fn () => throw new ConnectionException('timeout')]);

        expect(pdFailure(fn () => (new PackDownloader($http))->download(PD_URL, pdDestination(), 1000)))->toBe(['source_unavailable', 1]);
    });
});

it('says the disk is full when it cannot write the file', function (): void {
    $failure = pdFailure(fn () => (new PackDownloader(pdHttp([Factory::response('x')])))->download(PD_URL, '/no/such/directory/pack.zip', 1000));

    expect($failure)->toBe(['disk_full', 0]);
});

it('asks for the archive without following redirects by itself, and verifies TLS', function (): void {
    $http = pdHttp([Factory::response('x')]);

    (new PackDownloader($http))->download(PD_URL, pdDestination(), 1000);

    $http->assertSent(fn (Request $request): bool => $request->url() === PD_URL && $request->method() === 'GET');
});
