<?php

declare(strict_types=1);

namespace MinecraftSuite\Tests;

use Closure;
use MinecraftSuite\Support\RconClient;
use MinecraftSuite\Support\RconConnection;
use MinecraftSuite\Support\RconException;

/**
 * A scripted RCON socket. Every write is answered by $server, whose bytes queue up for the client to read, the
 * way a Minecraft server answers. A test can also make the stream end early or time out.
 */
final class FakeRconConnection implements RconConnection
{
    public string $buffer = '';

    /** @var list<string> */
    public array $written = [];

    public bool $closed = false;

    /** When the client reads past the end: true means the socket timed out, false means it was closed. */
    public bool $timesOut = false;

    /** @param Closure(string): string $server */
    public function __construct(private readonly Closure $server) {}

    public function write(string $bytes): void
    {
        $this->written[] = $bytes;
        $this->buffer .= ($this->server)($bytes);
    }

    /** Microseconds every read takes, to play a server that answers in slow drips. */
    public int $delayMicros = 0;

    public function read(int $length): string
    {
        if ($this->delayMicros > 0) {
            usleep($this->delayMicros);
        }

        if (strlen($this->buffer) < $length) {
            throw new RconException($this->timesOut ? RconException::TIMEOUT : RconException::ERROR, 'stream ended');
        }

        $chunk = substr($this->buffer, 0, $length);
        $this->buffer = (string) substr($this->buffer, $length);

        return $chunk;
    }

    public function close(): void
    {
        $this->closed = true;
    }

    /**
     * A Minecraft-like server: AUTH answers with AUTH_RESPONSE (id -1 when the password is wrong), a command
     * answers with its response parts, and the empty sentinel packet that follows a command is echoed back.
     *
     * @param  list<string>  $parts
     */
    public static function minecraft(string $password, array $parts = ['']): self
    {
        $server = static function (string $bytes) use ($password, $parts): string {
            $id = (int) unpack('V', substr($bytes, 4, 4))[1];
            $type = (int) unpack('V', substr($bytes, 8, 4))[1];
            $body = substr($bytes, 12, -2);

            if ($type === 3) {
                return RconClient::packet($body === $password ? $id : -1, 2, '');
            }
            if ($type === 2) {
                return implode('', array_map(static fn (string $part): string => RconClient::packet($id, 0, $part), $parts));
            }

            return RconClient::packet($id, 0, '');
        };

        return new self($server);
    }
}
