<?php

declare(strict_types=1);

namespace PlayerManager\Support;

/** The production RconConnection: a plain TCP socket, opened per command and closed when the command ends. */
final class SocketRconConnection implements RconConnection
{
    /** @param resource $socket */
    private function __construct(private readonly mixed $socket) {}

    public static function open(string $host, int $port, float $timeout): self
    {
        $address = str_contains($host, ':') ? "[{$host}]" : $host;
        $socket = @stream_socket_client("tcp://{$address}:{$port}", $errno, $error, $timeout);

        if ($socket === false) {
            throw new RconException(RconException::CONNECTION_FAILED, "{$errno} {$error}");
        }

        stream_set_timeout($socket, (int) $timeout, (int) (($timeout - (int) $timeout) * 1_000_000));

        return new self($socket);
    }

    public function write(string $bytes): void
    {
        if (fwrite($this->socket, $bytes) !== strlen($bytes)) {
            throw new RconException(RconException::ERROR, 'write failed');
        }
    }

    public function read(int $length): string
    {
        $data = '';

        while (strlen($data) < $length) {
            $chunk = fread($this->socket, $length - strlen($data));

            if ($chunk === false) {
                throw new RconException(RconException::ERROR, 'read failed');
            }
            if ($chunk === '') {
                $timedOut = stream_get_meta_data($this->socket)['timed_out'];

                throw new RconException($timedOut ? RconException::TIMEOUT : RconException::ERROR, 'stream ended');
            }

            $data .= $chunk;
        }

        return $data;
    }

    public function close(): void
    {
        fclose($this->socket);
    }
}
