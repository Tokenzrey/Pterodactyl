<?php

declare(strict_types=1);

namespace ModpackInstaller\Support;

use Closure;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\Response;
use RuntimeException;

/**
 * Downloads a modpack archive to a file, streaming, and refuses anything unexpected: an address off the allowed CDNs, a
 * redirect to one, more bytes than the limit, or a file that does not match the checksum the source gave (FR-MI8,
 * NFR-MI4, NFR-MI5).
 */
final class PackDownloader
{
    private const MAX_REDIRECTS = 3;

    private const READ_SIZE = 65536;

    /** The whole download may take this long, however slowly the CDN sends. */
    private const MAX_SECONDS = 3600;

    private const MAX_EMPTY_READS = 10;

    public function __construct(private readonly Factory $http) {}

    /**
     * @param  (Closure(int, ?int): void)|null  $progress  called with the bytes written so far and the total, if known
     * @return int the number of bytes written
     *
     * @throws ModpackJobException
     */
    public function download(string $url, string $destination, int $maxBytes, ?string $sha1 = null, ?Closure $progress = null): int
    {
        $response = $this->fetch($url);

        $length = $response->header('Content-Length');
        $total = is_numeric($length) ? (int) $length : null;
        if ($total !== null && $total > $maxBytes) {
            throw ModpackJobException::downloadTooLarge();
        }

        $written = $this->copy($response, $destination, $maxBytes, $total, $progress);

        // An archive that is not the one the source described is never handed to the server.
        if ($sha1 !== null && ! hash_equals($sha1, (string) hash_file('sha1', $destination))) {
            @unlink($destination);

            throw ModpackJobException::downloadFailed();
        }

        return $written;
    }

    /** Follows up to three redirects by hand, checking every address against the allow-list. */
    private function fetch(string $url): Response
    {
        for ($hop = 0; $hop <= self::MAX_REDIRECTS; $hop++) {
            if (DownloadUrlValidator::validate($url) !== null) {
                throw ModpackJobException::downloadFailed();
            }

            try {
                $response = $this->http
                    ->withHeaders(['Accept' => 'application/octet-stream'])
                    ->withOptions(['stream' => true, 'verify' => true, 'read_timeout' => 30])
                    ->timeout(1800)
                    ->connectTimeout(10)
                    ->withoutRedirecting()
                    ->get($url);
            } catch (ConnectionException) {
                throw ModpackJobException::sourceUnavailable();
            }

            $status = $response->status();
            if ($status >= 300 && $status < 400) {
                $location = $response->header('Location');
                if ($location === '' || $hop === self::MAX_REDIRECTS) {
                    throw ModpackJobException::downloadFailed();
                }
                $url = $this->resolve($url, $location);

                continue;
            }

            if ($status === 200) {
                return $response;
            }

            // A busy or broken CDN may recover; a missing file will not.
            throw $status === 429 || $status >= 500 ? ModpackJobException::sourceUnavailable() : ModpackJobException::downloadFailed();
        }

        throw ModpackJobException::downloadFailed();
    }

    /** A redirect may be absolute or relative to the address it came from. */
    private function resolve(string $base, string $location): string
    {
        if (preg_match('#\Ahttps?://#i', $location) === 1) {
            return $location;
        }

        $parts = parse_url($base);

        return 'https://'.($parts['host'] ?? '').(str_starts_with($location, '/') ? '' : '/').$location;
    }

    private function copy(Response $response, string $destination, int $maxBytes, ?int $total, ?Closure $progress): int
    {
        // Look first: a failed fopen() is also a PHP warning, and a full or missing disk is an ordinary case here.
        $handle = is_dir(dirname($destination)) && is_writable(dirname($destination)) ? fopen($destination, 'wb') : false;
        if ($handle === false) {
            throw ModpackJobException::diskFull();
        }

        $body = $response->toPsrResponse()->getBody();
        $written = 0;
        $empty = 0;
        $deadline = time() + self::MAX_SECONDS;

        try {
            while (! $body->eof()) {
                // A server that stops sending would otherwise keep this loop, and the worker, for ever.
                if (time() > $deadline) {
                    throw ModpackJobException::sourceUnavailable();
                }

                try {
                    $chunk = $body->read(self::READ_SIZE);
                } catch (RuntimeException) {
                    throw ModpackJobException::sourceUnavailable();
                }

                if ($chunk === '') {
                    if (++$empty >= self::MAX_EMPTY_READS) {
                        throw ModpackJobException::sourceUnavailable();
                    }

                    continue;
                }
                $empty = 0;

                $written += strlen($chunk);
                if ($written > $maxBytes) {
                    throw ModpackJobException::downloadTooLarge();
                }
                if (@fwrite($handle, $chunk) !== strlen($chunk)) {
                    throw ModpackJobException::diskFull();
                }

                $progress?->__invoke($written, $total);
            }
        } catch (ModpackJobException $exception) {
            fclose($handle);
            @unlink($destination);

            throw $exception;
        }

        fclose($handle);

        return $written;
    }
}
