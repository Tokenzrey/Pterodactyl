<?php

declare(strict_types=1);

namespace FileTransfer\Support;

use Closure;
use GuzzleHttp\Exception\ConnectException;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\Response;

/**
 * Downloads a public URL to a file, as a stream, within a size limit. What makes it safe to point at user input:
 *
 *  - every address a name resolves to must be public, and the connection is pinned to one of those addresses
 *    (curl's RESOLVE), so a second DNS answer cannot redirect it (T-FT2);
 *  - redirects are followed by hand, at most three, only to https, and each target goes through the same checks (EC-FT6);
 *  - the body is counted as it arrives and the download stops at the limit, whether or not the server said how big
 *    it is (FR-FT11, EC-FT7).
 */
final class RemoteFetcher
{
    public const MAX_REDIRECTS = 3;

    private const REDIRECTS = [301, 302, 303, 307, 308];

    private const CONNECT_TIMEOUT = 10;

    private const READ_TIMEOUT = 30;

    /** The whole download, however slow: the job's own time limit is the real stop. */
    private const TOTAL_TIMEOUT = 3600;

    /** @param  (Closure(string): list<string>)|null  $lookup  replaced by tests; DNS by default */
    public function __construct(private readonly Factory $http, private readonly ?Closure $lookup = null) {}

    /**
     * @param  Closure(int, ?int): void  $progress  called with the bytes written so far and the total when it is known
     *
     * @throws TransferException
     */
    public function download(string $url, string $destination, int $maxBytes, Closure $progress): void
    {
        $current = $url;
        for ($hop = 0; ; $hop++) {
            $response = $this->request($current, $hop > 0);
            if (! in_array($response->status(), self::REDIRECTS, true)) {
                break;
            }

            if ($hop >= self::MAX_REDIRECTS) {
                throw new TransferException('download_failed');
            }
            $current = self::redirectTarget($current, $response->header('Location'));
        }

        if (! $response->successful()) {
            // A server error or a rate limit can pass; "not found" and "forbidden" will not.
            throw new TransferException('download_failed', $response->serverError() || $response->status() === 429);
        }

        $length = $response->header('Content-Length');
        $total = ctype_digit($length) ? (int) $length : null;
        if ($total !== null && $total > $maxBytes) {
            throw new TransferException('download_too_large');
        }

        $this->write($response, $destination, $maxBytes, $total, $progress);
    }

    private function request(string $url, bool $isRedirect): Response
    {
        // A redirect may only lead to https, and is checked as strictly as the first address was.
        if (RemoteUrlValidator::validate($url) !== null || ($isRedirect && ! str_starts_with(strtolower($url), 'https://'))) {
            throw new TransferException('invalid_url');
        }

        $parts = parse_url($url);
        $host = RemoteUrlValidator::host((string) $parts['host']);
        $port = $parts['port'] ?? (strtolower((string) $parts['scheme']) === 'https' ? 443 : 80);

        $addresses = RemoteUrlValidator::resolve($host, $this->lookup);
        if ($addresses === null) {
            throw new TransferException('invalid_url');
        }
        if ($addresses === []) {
            // Not resolvable now. It may be later.
            throw new TransferException('download_failed', true);
        }

        $options = ['stream' => true, 'read_timeout' => self::READ_TIMEOUT];
        if (defined('CURLOPT_RESOLVE')) {
            $address = str_contains($addresses[0], ':') ? "[{$addresses[0]}]" : $addresses[0];
            $options['curl'] = [CURLOPT_RESOLVE => ["{$host}:{$port}:{$address}"]];
        }

        try {
            return $this->http
                ->withOptions($options)
                ->withHeaders(['Accept' => '*/*', 'User-Agent' => 'Pterodactyl-FileTransfer/1.0'])
                ->connectTimeout(self::CONNECT_TIMEOUT)
                ->timeout(self::TOTAL_TIMEOUT)
                ->withoutRedirecting()
                ->get($url);
        } catch (ConnectionException $exception) {
            throw new TransferException(self::connectionReason($exception), true);
        }
    }

    /** @param  Closure(int, ?int): void  $progress */
    private function write(Response $response, string $destination, int $maxBytes, ?int $total, Closure $progress): void
    {
        $directory = dirname($destination);
        if (! is_dir($directory) && ! mkdir($directory, 0700, true) && ! is_dir($directory)) {
            throw new TransferException('download_failed');
        }

        $source = $response->resource();
        $target = fopen($destination, 'wb');
        if ($target === false) {
            throw new TransferException('download_failed');
        }

        $written = 0;
        try {
            while (! feof($source)) {
                $bytes = fread($source, 65536);
                if ($bytes === false) {
                    throw new TransferException(stream_get_meta_data($source)['timed_out'] ? 'timeout' : 'download_failed', true);
                }

                $written += strlen($bytes);
                if ($written > $maxBytes) {
                    throw new TransferException('download_too_large');
                }

                fwrite($target, $bytes);
                $progress($written, $total);
            }
        } finally {
            fclose($target);
        }
    }

    /** The absolute URL a Location header points to, from a full URL, a "//host/path", a "/path" or a relative path. */
    private static function redirectTarget(string $current, string $location): string
    {
        if ($location === '') {
            throw new TransferException('download_failed');
        }

        if (isset(parse_url($location)['scheme'])) {
            return $location;
        }

        $base = parse_url($current);
        $origin = $base['scheme'].'://'.$base['host'].(isset($base['port']) ? ':'.$base['port'] : '');

        return match (true) {
            str_starts_with($location, '//') => $base['scheme'].':'.$location,
            str_starts_with($location, '/') => $origin.$location,
            default => $origin.rtrim(dirname($base['path'] ?? '/'), '/').'/'.$location,
        };
    }

    /** curl error 28 is a timeout, 6 and 7 are "could not resolve" and "could not connect". */
    private static function connectionReason(ConnectionException $exception): string
    {
        $previous = $exception->getPrevious();
        $errno = $previous instanceof ConnectException ? ($previous->getHandlerContext()['errno'] ?? 0) : 0;

        return match (true) {
            $errno === 28 => 'timeout',
            in_array($errno, [6, 7], true) => 'connection_refused',
            default => 'download_failed',
        };
    }
}
