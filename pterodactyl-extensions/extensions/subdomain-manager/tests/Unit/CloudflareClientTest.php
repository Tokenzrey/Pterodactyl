<?php

declare(strict_types=1);

use GuzzleHttp\Promise\PromiseInterface;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\Request;
use Psr\Http\Message\RequestInterface;
use SubdomainManager\Support\CloudflareClient;
use SubdomainManager\Support\CloudflareException;
use SubdomainManager\Support\Payloads;

// NFR-S3, NFR-S4, NFR-S5, AC-S15, EC-S2, EC-S3, EC-S7, Fokus-3. No network: a standalone HTTP factory with
// stray requests prevented; bodies shaped like Cloudflare's API documentation.

const CF_TOKEN = 'cf-secret-token-DO-NOT-LEAK-0123456789';
const CF_ZONE = '023e105f4ecef8ad9ca31a8372d0c353';
const CF_ID = '372e67954025e0ba6aaa6d586b9e0b59';
const CF_BASE = 'https://api.cloudflare.com/client/v4';

/**
 * @param  callable(Request): PromiseInterface  $handler
 * @param  array<int, array<string, mixed>>  $options  Guzzle options of every request
 */
function cfHttp(callable $handler, array &$options = []): Factory
{
    $http = new Factory;
    $http->preventStrayRequests();
    $http->globalMiddleware(function (callable $next) use (&$options): Closure {
        return function (RequestInterface $request, array $opts) use ($next, &$options) {
            $options[] = $opts;

            return $next($request, $opts);
        };
    });
    $http->fake($handler);

    return $http;
}

function cfClient(Factory $http): CloudflareClient
{
    return new CloudflareClient($http, CF_TOKEN);
}

function cfOk(mixed $result): PromiseInterface
{
    return Factory::response(['success' => true, 'errors' => [], 'messages' => [], 'result' => $result]);
}

function cfError(int $status, int $code, string $message): PromiseInterface
{
    return Factory::response(['success' => false, 'errors' => [['code' => $code, 'message' => $message]], 'messages' => [], 'result' => null], $status);
}

/** @return list<Request> */
function cfSent(Factory $http): array
{
    return array_map(fn (array $pair): Request => $pair[0], $http->recorded()->all());
}

function cfFailure(callable $call): ?CloudflareException
{
    try {
        $call();
    } catch (CloudflareException $e) {
        return $e;
    }

    return null;
}

function cfRecord(array $override = []): array
{
    return $override + ['id' => CF_ID, 'type' => 'A', 'name' => 'kampung.mc.example.com', 'content' => '203.0.113.10', 'proxied' => false, 'ttl' => 120];
}

describe('requests', function (): void {
    test('NFR-S3 every call goes to the fixed API with a Bearer token, JSON, a 10 second timeout, no redirects and TLS verification', function (): void {
        $options = [];
        $http = cfHttp(fn (Request $r) => match (true) {
            $r->method() === 'POST' => cfOk(['id' => CF_ID]),
            $r->method() === 'DELETE' => cfOk(['id' => CF_ID]),
            default => cfOk([]),
        }, $options);
        $client = cfClient($http);

        $client->ping(CF_ZONE);
        $client->findRecords(CF_ZONE, 'A', 'kampung.mc.example.com');
        $client->createRecord(CF_ZONE, Payloads::a('kampung.mc.example.com', '203.0.113.10', 120, 'u'));
        $client->deleteRecord(CF_ZONE, CF_ID);

        expect(cfSent($http))->toHaveCount(4);
        foreach (cfSent($http) as $request) {
            expect($request->url())->toStartWith(CF_BASE.'/zones/'.CF_ZONE.'/dns_records')
                ->and($request->header('Authorization'))->toBe(['Bearer '.CF_TOKEN])
                ->and($request->header('Accept'))->toBe(['application/json'])
                ->and($request->url())->not->toContain(CF_TOKEN);
        }
        expect($options)->toHaveCount(4);
        foreach ($options as $opts) {
            expect($opts['allow_redirects'])->toBeFalse()
                ->and($opts['timeout'])->toBe(10)
                ->and($opts['verify'] ?? true)->not->toBeFalse();
        }
    });

    test('ping lists one record, which needs a valid token and a readable zone', function (): void {
        $http = cfHttp(fn () => cfOk([]));

        cfClient($http)->ping(CF_ZONE);

        [$request] = cfSent($http);
        expect($request->method())->toBe('GET')
            ->and($request->url())->toBe(CF_BASE.'/zones/'.CF_ZONE.'/dns_records?per_page=1');
    });

    test('findRecords asks for an exact name and type', function (): void {
        $http = cfHttp(fn () => cfOk([]));

        cfClient($http)->findRecords(CF_ZONE, 'SRV', '_minecraft._tcp.kampung.mc.example.com');

        [$request] = cfSent($http);
        expect($request->method())->toBe('GET')
            ->and(parse_url($request->url(), PHP_URL_PATH))->toBe('/client/v4/zones/'.CF_ZONE.'/dns_records')
            ->and(parse_url($request->url(), PHP_URL_QUERY))->toBe('type=SRV&name.exact=_minecraft._tcp.kampung.mc.example.com&per_page=100');
    });

    test('createRecord posts the payload as JSON and returns the new record id', function (): void {
        $http = cfHttp(fn () => cfOk(['id' => CF_ID, 'type' => 'A']));
        $payload = Payloads::a('kampung.mc.example.com', '203.0.113.10', 120, 'u');

        expect(cfClient($http)->createRecord(CF_ZONE, $payload))->toBe(CF_ID);

        [$request] = cfSent($http);
        expect($request->method())->toBe('POST')
            ->and($request->url())->toBe(CF_BASE.'/zones/'.CF_ZONE.'/dns_records')
            ->and($request->isJson())->toBeTrue()
            ->and($request->data())->toBe($payload);
    });

    test('deleteRecord deletes exactly the record id it is given', function (): void {
        $http = cfHttp(fn () => cfOk(['id' => CF_ID]));

        cfClient($http)->deleteRecord(CF_ZONE, CF_ID);

        [$request] = cfSent($http);
        expect($request->method())->toBe('DELETE')
            ->and($request->url())->toBe(CF_BASE.'/zones/'.CF_ZONE.'/dns_records/'.CF_ID);
    });

    test('NFR-S5 there is no way to delete by name: the public surface is fixed', function (): void {
        $methods = array_map(fn (ReflectionMethod $m): string => $m->getName(), (new ReflectionClass(CloudflareClient::class))->getMethods(ReflectionMethod::IS_PUBLIC));
        $delete = new ReflectionMethod(CloudflareClient::class, 'deleteRecord');

        expect($methods)->toEqualCanonicalizing(['__construct', 'ping', 'findRecords', 'createRecord', 'deleteRecord'])
            ->and(array_map(fn (ReflectionParameter $p): string => $p->getName(), $delete->getParameters()))->toBe(['zone', 'id']);
    });

    test('a zone or record id that is not what Cloudflare issues never reaches a URL', function (callable $call): void {
        $http = cfHttp(fn () => cfOk([]));

        expect(fn () => $call(cfClient($http)))->toThrow(InvalidArgumentException::class);
        expect(cfSent($http))->toBe([]);
    })->with([
        'zone with a slash' => [fn (CloudflareClient $c) => $c->ping('abc/../def')],
        'zone too short' => [fn (CloudflareClient $c) => $c->ping('abc')],
        'zone upper case' => [fn (CloudflareClient $c) => $c->ping(strtoupper(CF_ZONE))],
        'record id with traversal' => [fn (CloudflareClient $c) => $c->deleteRecord(CF_ZONE, '../zones')],
        'record id with a query' => [fn (CloudflareClient $c) => $c->deleteRecord(CF_ZONE, CF_ID.'?x=1')],
        'empty record id' => [fn (CloudflareClient $c) => $c->deleteRecord(CF_ZONE, '')],
        'record type that is not a word' => [fn (CloudflareClient $c) => $c->findRecords(CF_ZONE, 'A&x=1', 'a.example.com')],
    ]);
});

describe('findRecords answers', function (): void {
    test('only records whose type and name really match are returned (name.exact is re-checked)', function (): void {
        $http = cfHttp(fn () => cfOk([
            cfRecord(),
            cfRecord(['id' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'name' => 'KAMPUNG.mc.example.com']),
            cfRecord(['id' => 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'name' => 'other.mc.example.com']),
            cfRecord(['id' => 'cccccccccccccccccccccccccccccccc', 'type' => 'CNAME']),
            cfRecord(['id' => '../zones', 'name' => 'kampung.mc.example.com']),
            'junk',
            ['type' => 'A', 'name' => 'kampung.mc.example.com'],
        ]));

        $found = cfClient($http)->findRecords(CF_ZONE, 'A', 'kampung.mc.example.com');

        expect(array_column($found, 'id'))->toBe([CF_ID, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa']);
    });

    test('an empty result is an empty list', function (): void {
        expect(cfClient(cfHttp(fn () => cfOk([])))->findRecords(CF_ZONE, 'A', 'x.example.com'))->toBe([]);
    });

    test('a result that is not a list is a failure, not "no records" (which would let a create through)', function (mixed $result): void {
        $e = cfFailure(fn () => cfClient(cfHttp(fn () => cfOk($result)))->findRecords(CF_ZONE, 'A', 'x.example.com'));

        expect($e)->toBeInstanceOf(CloudflareException::class);
    })->with([null, 'nope', [['id' => CF_ID]], 5]); // [['id' => ...]]: one object where a list belongs
});

describe('failures', function (): void {
    test('EC-S2 429 and 5xx are retryable, 4xx other than 429 are not', function (int $status, bool $retryable): void {
        $e = cfFailure(fn () => cfClient(cfHttp(fn () => cfError($status, 1000, 'x')))->ping(CF_ZONE));

        expect($e)->toBeInstanceOf(CloudflareException::class)
            ->and($e->retryable)->toBe($retryable)
            ->and($e->status)->toBe($status);
    })->with([
        [429, true], [500, true], [502, true], [503, true], [504, true],
        [400, false], [401, false], [403, false], [404, false], [409, false], [422, false],
    ]);

    test('a redirect is never followed and counts as a permanent failure', function (): void {
        $e = cfFailure(fn () => cfClient(cfHttp(fn () => Factory::response('', 302, ['Location' => 'https://evil.example/'])))->ping(CF_ZONE));

        expect($e)->not->toBeNull()->and($e->retryable)->toBeFalse();
    });

    test('a dropped connection is retryable', function (): void {
        $e = cfFailure(fn () => cfClient(cfHttp(Factory::failedConnection('cURL error 28: Operation timed out')))->ping(CF_ZONE));

        expect($e)->not->toBeNull()->and($e->retryable)->toBeTrue();
    });

    test('Fokus-3 HTTP 200 with success:false is a failure, never a success', function (callable $call): void {
        $http = cfHttp(fn () => Factory::response(['success' => false, 'errors' => [['code' => 81057, 'message' => 'The record already exists.']], 'result' => ['id' => CF_ID]], 200));

        $e = cfFailure(fn () => $call(cfClient($http)));

        expect($e)->toBeInstanceOf(CloudflareException::class)->and($e->safe)->toBe('81057: The record already exists.');
    })->with([
        'ping' => [fn (CloudflareClient $c) => $c->ping(CF_ZONE)],
        'find' => [fn (CloudflareClient $c) => $c->findRecords(CF_ZONE, 'A', 'x.example.com')],
        'create' => [fn (CloudflareClient $c) => $c->createRecord(CF_ZONE, Payloads::a('x.example.com', '203.0.113.10', 120, 'u'))],
        'delete' => [fn (CloudflareClient $c) => $c->deleteRecord(CF_ZONE, CF_ID)],
    ]);

    test('EC-S3 a body that is not JSON, or a created record without a usable id, is a retryable failure', function (mixed $response): void {
        $e = cfFailure(fn () => cfClient(cfHttp(fn () => $response))->createRecord(CF_ZONE, Payloads::a('x.example.com', '203.0.113.10', 120, 'u')));

        expect($e)->toBeInstanceOf(CloudflareException::class)->and($e->retryable)->toBeTrue();
    })->with([
        'html' => [fn () => Factory::response('<html>502</html>', 200)],
        'empty body' => [fn () => Factory::response('', 200)],
        'no result' => [fn () => Factory::response(['success' => true], 200)],
        'result without id' => [fn () => cfOk(['type' => 'A'])],
        'id that is a number' => [fn () => cfOk(['id' => 12])],
        'id with a slash' => [fn () => cfOk(['id' => 'abc/../def'])],
        'result is a list' => [fn () => cfOk([['id' => CF_ID]])],
    ]);

    test('EC-S4 deleting a record that is already gone is success', function (): void {
        $http = cfHttp(fn () => cfError(404, 81044, 'Record does not exist.'));

        cfClient($http)->deleteRecord(CF_ZONE, CF_ID);

        expect(cfSent($http))->toHaveCount(1);
    });

    test('a failed delete other than 404 is an error', function (int $status, bool $retryable): void {
        $e = cfFailure(fn () => cfClient(cfHttp(fn () => cfError($status, 1, 'x')))->deleteRecord(CF_ZONE, CF_ID));

        expect($e)->not->toBeNull()->and($e->retryable)->toBe($retryable);
    })->with([[403, false], [429, true], [500, true]]);
});

describe('error text (NFR-S4, AC-S15, FR-S12)', function (): void {
    test('only the first "code: message" is kept', function (): void {
        $http = cfHttp(fn () => Factory::response(['success' => false, 'errors' => [['code' => 10000, 'message' => 'Authentication error'], ['code' => 9109, 'message' => 'Second']]], 403));

        $e = cfFailure(fn () => cfClient($http)->ping(CF_ZONE));

        expect($e->safe)->toBe('10000: Authentication error')->and($e->getMessage())->toBe($e->safe);
    });

    test('it is cut to 200 characters', function (): void {
        $e = cfFailure(fn () => cfClient(cfHttp(fn () => cfError(400, 1004, str_repeat('long ', 200))))->ping(CF_ZONE));

        expect(strlen($e->safe))->toBeLessThanOrEqual(200)->and($e->safe)->toStartWith('1004: long long');
    });

    test('control characters and line breaks are flattened', function (): void {
        $e = cfFailure(fn () => cfClient(cfHttp(fn () => cfError(400, 1, "bad\r\nrequest\x00\x1b[31m here")))->ping(CF_ZONE));

        expect($e->safe)->not->toMatch('/[\x00-\x1f\x7f]/')->and($e->safe)->toStartWith('1: bad request');
    });

    test('the token is redacted even if Cloudflare were to echo it back', function (): void {
        $e = cfFailure(fn () => cfClient(cfHttp(fn () => cfError(403, 6003, 'Invalid request headers: Bearer '.CF_TOKEN)))->ping(CF_ZONE));

        expect($e->safe)->not->toContain(CF_TOKEN)->and($e->getMessage())->not->toContain(CF_TOKEN)->and($e->safe)->toContain('[redacted]');
    });

    test('without an error list the status code is all that is said', function (): void {
        $e = cfFailure(fn () => cfClient(cfHttp(fn () => Factory::response('Bad gateway', 502)))->ping(CF_ZONE));

        expect($e->safe)->toBe('HTTP 502');
    });

    test('nothing in the exception carries the token, the response body or a previous exception', function (): void {
        $e = cfFailure(fn () => cfClient(cfHttp(Factory::failedConnection('cURL error 7 for https://api.cloudflare.com/ with '.CF_TOKEN)))->ping(CF_ZONE));

        expect($e->getPrevious())->toBeNull()
            ->and($e->getMessage())->not->toContain(CF_TOKEN)
            ->and($e->getTraceAsString())->not->toContain(CF_TOKEN);
    });
});
