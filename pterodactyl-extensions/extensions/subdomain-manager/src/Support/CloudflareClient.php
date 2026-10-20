<?php

declare(strict_types=1);

namespace SubdomainManager\Support;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\PendingRequest;
use Illuminate\Http\Client\Response;
use InvalidArgumentException;

/**
 * The few Cloudflare DNS calls this extension needs. The API address is a constant, every request has a
 * 10 second timeout, follows no redirects and verifies TLS, and the token only ever travels in the
 * Authorization header. Records are deleted by id and never by name: there is no method that could.
 */
final class CloudflareClient
{
    public const BASE = 'https://api.cloudflare.com/client/v4';

    private const TIMEOUT = 10;

    private const CONNECT_TIMEOUT = 5;

    private const MAX_ERROR_LENGTH = 200;

    public function __construct(private readonly Factory $http, #[\SensitiveParameter] private readonly string $token) {}

    /** Reads one record, which proves the token works and can see the zone. @throws CloudflareException */
    public function ping(string $zone): void
    {
        $this->decode($this->send(fn () => $this->request()->get($this->records($zone), ['per_page' => 1])));
    }

    /**
     * Records of the given type and exact name. Cloudflare filters on `name.exact`; the answer is checked
     * again here, so a looser match on its side can never make a stranger's record look like ours.
     *
     * @return list<array<string, mixed>> only entries with a usable id
     *
     * @throws CloudflareException
     */
    public function findRecords(string $zone, string $type, string $name): array
    {
        if (preg_match('/^[A-Z]{1,10}$/D', $type) !== 1) {
            throw new InvalidArgumentException('Invalid DNS record type.');
        }

        $result = $this->decode($this->send(fn () => $this->request()->get($this->records($zone), ['type' => $type, 'name.exact' => $name, 'per_page' => 100])))['result'] ?? null;
        if (! is_array($result) || ! array_is_list($result)) {
            throw new CloudflareException(true, 'Cloudflare returned a record list in an unexpected shape');
        }

        return array_values(array_filter($result, fn (mixed $record): bool => is_array($record)
            && self::isId($record['id'] ?? null)
            && ($record['type'] ?? null) === $type
            && is_string($record['name'] ?? null)
            && strtolower($record['name']) === strtolower($name)));
    }

    /**
     * @param  array<string, mixed>  $payload  see Payloads
     * @return string the id Cloudflare gave the new record
     *
     * @throws CloudflareException
     */
    public function createRecord(string $zone, array $payload): string
    {
        $id = $this->decode($this->send(fn () => $this->request()->asJson()->post($this->records($zone), $payload)))['result']['id'] ?? null;

        return self::isId($id) ? $id : throw new CloudflareException(true, 'Cloudflare created a record but returned no usable id');
    }

    /** A record that is already gone (404) counts as deleted. @throws CloudflareException */
    public function deleteRecord(string $zone, string $id): void
    {
        if (! self::isId($id)) {
            throw new InvalidArgumentException('Invalid DNS record id.');
        }

        $response = $this->send(fn () => $this->request()->delete($this->records($zone).'/'.$id));
        if ($response->status() !== 404) {
            $this->decode($response);
        }
    }

    private function records(string $zone): string
    {
        if (preg_match('/^[a-f0-9]{32}$/D', $zone) !== 1) {
            throw new InvalidArgumentException('Invalid Cloudflare zone id.');
        }

        return self::BASE.'/zones/'.$zone.'/dns_records';
    }

    private function request(): PendingRequest
    {
        return $this->http->acceptJson()
            ->withToken($this->token)
            ->connectTimeout(self::CONNECT_TIMEOUT)
            ->timeout(self::TIMEOUT)
            ->withoutRedirecting();
    }

    private function send(callable $call): Response
    {
        try {
            return $call();
        } catch (ConnectionException) {
            throw new CloudflareException(true, 'Connection to Cloudflare failed or timed out');
        }
    }

    /**
     * The decoded body of a successful answer. HTTP 200 alone is not success: Cloudflare says so in `success`.
     *
     * @return array<string, mixed>
     *
     * @throws CloudflareException
     */
    private function decode(Response $response): array
    {
        $body = $response->json();
        $status = $response->status();

        if (! $response->successful() || (is_array($body) && ($body['success'] ?? null) === false)) {
            // 429 and 5xx are worth another try; a refusal (auth, validation, a 200 that says no) is not.
            throw new CloudflareException($status === 429 || $status >= 500, $this->describe($status, $body), $status);
        }

        if (! is_array($body) || ($body['success'] ?? null) !== true) {
            throw new CloudflareException(true, 'Cloudflare returned something that is not a JSON answer', $status);
        }

        return $body;
    }

    /** The first error as "code: message", free of control characters and the token, at most 200 characters. */
    private function describe(int $status, mixed $body): string
    {
        $error = is_array($body) && is_array($body['errors'] ?? null) ? ($body['errors'][0] ?? null) : null;
        $text = is_array($error) && is_string($error['message'] ?? null)
            ? (is_int($error['code'] ?? null) ? $error['code'].': ' : '').$error['message']
            : 'HTTP '.$status;

        $text = str_replace($this->token, '[redacted]', $text);
        $text = preg_replace('/[\x00-\x20\x7f]+/', ' ', $text) ?? 'HTTP '.$status;

        return mb_substr(trim($text), 0, self::MAX_ERROR_LENGTH);
    }

    private static function isId(mixed $id): bool
    {
        return is_string($id) && preg_match('/^[A-Za-z0-9]{1,64}$/D', $id) === 1;
    }
}
