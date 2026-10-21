<?php

declare(strict_types=1);

namespace PlayerManager\Support;

use Closure;
use InvalidArgumentException;

/**
 * Source RCON, the protocol Minecraft speaks on its RCON port. One connection per command: open, authenticate,
 * send, read the response, close. Panel never talks RCON over HTTP (FR-PM3); the socket is opened from PHP.
 *
 * Every failure is an RconException with one of the fixed codes. The host and port come only from the server's
 * settings, validated here (NFR-PM3).
 */
final class RconClient
{
    public const TIMEOUT = 5.0;

    /** The most a whole exchange (connect excluded) may take, in seconds. */
    public const DEADLINE = 10.0;

    /** The most one Source RCON packet may carry in its body. */
    private const MAX_BODY = 4096;

    /** Upper bound on a whole response, so a misbehaving server cannot exhaust memory. */
    private const MAX_RESPONSE = 65536;

    private const AUTH = 3;

    private const EXEC = 2;

    private const AUTH_RESPONSE = 2;

    private const RESPONSE = 0;

    private const AUTH_ID = 1;

    private const COMMAND_ID = 2;

    private const SENTINEL_ID = 3;

    /** @var Closure(string, int, float): RconConnection */
    private readonly Closure $open;

    /**
     * @param  (Closure(string, int, float): RconConnection)|null  $open  replaced by tests; the socket by default
     * @param  float  $deadline  seconds the whole exchange may take. Each read has its own 5 s timeout, but a server
     *                           that answers in slow drips would otherwise keep a PHP worker busy far longer.
     */
    public function __construct(private readonly string $host, private readonly int $port, private readonly string $password, ?Closure $open = null, private readonly float $deadline = self::DEADLINE)
    {
        if (! self::validHost($host) || $port < 1 || $port > 65535 || $password === '' || str_contains($password, "\0")) {
            throw new RconException(RconException::NOT_CONFIGURED);
        }

        $this->open = $open ?? static fn (string $host, int $port, float $timeout): RconConnection => SocketRconConnection::open($host, $port, $timeout);
    }

    /**
     * One packet on the wire: length (the bytes after it), id, type, body, and two null bytes. Public so tests can
     * play the server's side with the same encoding.
     */
    public static function packet(int $id, int $type, string $body): string
    {
        return pack('V', strlen($body) + 10).pack('V', $id).pack('V', $type).$body."\0\0";
    }

    /** Sends one command and returns the text of its response. @throws RconException */
    public function command(string $command): string
    {
        if (str_contains($command, "\0") || strlen($command) > self::MAX_BODY) {
            throw new InvalidArgumentException('The command cannot be sent over RCON.');
        }

        $connection = ($this->open)($this->host, $this->port, self::TIMEOUT);

        try {
            $until = microtime(true) + $this->deadline;
            $this->authenticate($connection, $until);

            return $this->exchange($connection, $command, $until);
        } finally {
            $connection->close();
        }
    }

    private function authenticate(RconConnection $connection, float $until): void
    {
        $connection->write(self::packet(self::AUTH_ID, self::AUTH, $this->password));

        [$id, $type] = $this->read($connection, $until);
        if ($type === self::RESPONSE) {
            // Some servers send an empty RESPONSE_VALUE before the AUTH_RESPONSE.
            [$id, $type] = $this->read($connection, $until);
        }

        if ($type !== self::AUTH_RESPONSE) {
            throw new RconException(RconException::ERROR, 'no auth response');
        }
        if ($id === -1) {
            throw new RconException(RconException::AUTH_FAILED);
        }
        if ($id !== self::AUTH_ID) {
            throw new RconException(RconException::ERROR, 'unexpected auth id');
        }
    }

    private function exchange(RconConnection $connection, string $command, float $until): string
    {
        $connection->write(self::packet(self::COMMAND_ID, self::EXEC, $command));
        $connection->write(self::packet(self::SENTINEL_ID, self::RESPONSE, ''));

        // A response can span several packets. The server echoes the empty sentinel after the last one.
        $text = '';
        while (true) {
            [$id, , $body] = $this->read($connection, $until);

            if ($id === self::SENTINEL_ID) {
                return $text;
            }
            if ($id !== self::COMMAND_ID) {
                throw new RconException(RconException::ERROR, 'unexpected response id');
            }

            $text .= $body;
            if (strlen($text) > self::MAX_RESPONSE) {
                throw new RconException(RconException::ERROR, 'response too large');
            }
        }
    }

    /** @return array{int, int, string} id, type, body */
    private function read(RconConnection $connection, float $until): array
    {
        if (microtime(true) > $until) {
            throw new RconException(RconException::TIMEOUT, 'deadline passed');
        }

        $size = self::int32($connection->read(4));
        if ($size < 10 || $size > self::MAX_BODY + 10) {
            throw new RconException(RconException::ERROR, 'bad packet length');
        }

        $payload = $connection->read($size);

        return [self::int32(substr($payload, 0, 4)), self::int32(substr($payload, 4, 4)), substr($payload, 8, -2)];
    }

    /** A little-endian signed 32-bit integer; the auth failure id is -1 on the wire. */
    private static function int32(string $bytes): int
    {
        $value = unpack('V', $bytes)[1];

        return $value >= 0x80000000 ? $value - 0x100000000 : $value;
    }

    /** An IPv4 or IPv6 address, or a host name of at most 253 characters. Nothing with a scheme, a path or a space. */
    public static function validHost(string $host): bool
    {
        if ($host === '' || strlen($host) > 253) {
            return false;
        }
        if (filter_var($host, FILTER_VALIDATE_IP) !== false) {
            return true;
        }

        return preg_match('/^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))*$/i', $host) === 1;
    }
}
