<?php

declare(strict_types=1);

namespace SubdomainManager\Tests;

use GuzzleHttp\Promise\PromiseInterface;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;

/**
 * A small in-memory Cloudflare DNS API: enough of the real one (list with filters, create, delete by id,
 * 404 for unknown ids, several zones) to test the syncer against state instead of canned replies. Like the
 * real API it happily takes a second A record with the same name, which is exactly why the extension has to
 * look before it creates. Failures can be queued per method and record type.
 */
final class FakeCloudflare
{
    public const ZONE = '023e105f4ecef8ad9ca31a8372d0c353';

    public const OTHER_ZONE = 'ffffffffffffffffffffffffffffffff';

    /** @var array<string, array<string, array<string, mixed>>> zone => id => record */
    public array $zones = [];

    /** @var list<array{method: string, type: ?string, name: ?string, id: ?string, zone: string}> */
    public array $calls = [];

    /** @var list<array{method: string, type: ?string, status: int, code: int, message: string}> */
    private array $failures = [];

    private int $counter = 0;

    /**
     * @param  bool  $fresh  replace the HTTP client first, so no earlier fake can answer; pass false to
     *                       add this fake to others (the Panel's fake Wings), which it leaves alone
     */
    public function install(bool $fresh = true): self
    {
        if ($fresh) {
            Http::swap(new Factory);
            Http::preventStrayRequests();
        }
        Http::fake(fn (Request $request): ?PromiseInterface => $this->handle($request));

        return $this;
    }

    /** A record somebody else made. @param array<string, mixed> $extra */
    public function seed(string $type, string $name, array $extra = [], string $zone = self::ZONE): string
    {
        $id = $this->newId();
        $this->zones[$zone][$id] = ['id' => $id, 'type' => $type, 'name' => $name, 'content' => '198.51.100.7', 'ttl' => 300, ...$extra];

        return $id;
    }

    /** The next matching call fails with this status and Cloudflare error. */
    public function failNext(string $method, int $status, ?string $type = null, int $code = 1000, string $message = 'boom'): self
    {
        $this->failures[] = compact('method', 'type', 'status', 'code', 'message');

        return $this;
    }

    /** @return list<array<string, mixed>> */
    public function named(string $type, string $name, string $zone = self::ZONE): array
    {
        return array_values(array_filter($this->zones[$zone] ?? [], fn (array $r): bool => $r['type'] === $type && strtolower($r['name']) === strtolower($name)));
    }

    /** @return list<array<string, mixed>> */
    public function all(string $zone = self::ZONE): array
    {
        return array_values($this->zones[$zone] ?? []);
    }

    public function count(string $method, ?string $type = null): int
    {
        return count(array_filter($this->calls, fn (array $c): bool => $c['method'] === $method && ($type === null || $c['type'] === $type)));
    }

    /** @return list<string> "METHOD TYPE-or-id" in the order the calls were made */
    public function trace(): array
    {
        return array_map(fn (array $c): string => $c['method'].' '.($c['id'] ?? $c['type']), $this->calls);
    }

    private function handle(Request $request): ?PromiseInterface
    {
        if (parse_url($request->url(), PHP_URL_HOST) !== 'api.cloudflare.com') {
            return null; // not ours: let the next fake answer
        }

        $path = (string) parse_url($request->url(), PHP_URL_PATH);
        if (preg_match('#^/client/v4/zones/([a-f0-9]{32})/dns_records(?:/([A-Za-z0-9]+))?$#D', $path, $m) !== 1) {
            return $this->error(404, 7000, 'No route for that URI');
        }
        [, $zone, $id] = $m + [2 => null];

        parse_str((string) parse_url($request->url(), PHP_URL_QUERY), $query); // PHP turns "name.exact" into "name_exact"
        $payload = $request->method() === 'POST' ? $request->data() : [];
        $type = $payload['type'] ?? $query['type'] ?? null;
        $name = $payload['name'] ?? $query['name_exact'] ?? null;
        $this->calls[] = ['method' => $request->method(), 'type' => $type, 'name' => $name, 'id' => $id, 'zone' => $zone];

        foreach ($this->failures as $i => $failure) {
            if ($failure['method'] === $request->method() && ($failure['type'] === null || $failure['type'] === $type)) {
                unset($this->failures[$i]);

                return $this->error($failure['status'], $failure['code'], $failure['message']);
            }
        }

        if (! isset($this->zones[$zone]) && ! in_array($zone, [self::ZONE, self::OTHER_ZONE], true)) {
            return $this->error(404, 7003, 'Could not route to /zones/'.$zone);
        }

        return match ($request->method()) {
            'GET' => $this->ok(array_values(array_filter(
                $this->zones[$zone] ?? [],
                fn (array $r): bool => ($type === null || $r['type'] === $type) && ($name === null || strtolower($r['name']) === strtolower($name)),
            ))),
            'POST' => $this->create($zone, $payload),
            'DELETE' => $id !== null && isset($this->zones[$zone][$id])
                ? $this->deleted($zone, $id)
                : $this->error(404, 81044, 'Record does not exist.'),
            default => $this->error(405, 1000, 'Method not allowed'),
        };
    }

    /** @param array<string, mixed> $payload */
    private function create(string $zone, array $payload): PromiseInterface
    {
        $id = $this->newId();
        $this->zones[$zone][$id] = ['id' => $id, ...$payload];

        return $this->ok($this->zones[$zone][$id]);
    }

    private function deleted(string $zone, string $id): PromiseInterface
    {
        unset($this->zones[$zone][$id]);

        return $this->ok(['id' => $id]);
    }

    private function newId(): string
    {
        return substr(hash('sha256', 'record-'.++$this->counter), 0, 32);
    }

    private function ok(mixed $result): PromiseInterface
    {
        return Factory::response(['success' => true, 'errors' => [], 'messages' => [], 'result' => $result]);
    }

    private function error(int $status, int $code, string $message): PromiseInterface
    {
        return Factory::response(['success' => false, 'errors' => [['code' => $code, 'message' => $message]], 'messages' => [], 'result' => null], $status);
    }
}
