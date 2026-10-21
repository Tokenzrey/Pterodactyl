<?php

declare(strict_types=1);

namespace PlayerManager\Support;

/** The byte stream RconClient talks over. A real socket in production; a scripted fake in tests. */
interface RconConnection
{
    /** @throws RconException rcon_error when the stream cannot take the bytes */
    public function write(string $bytes): void;

    /**
     * Reads exactly $length bytes.
     *
     * @throws RconException rcon_timeout when the stream stays silent, rcon_error when it ends first
     */
    public function read(int $length): string;

    public function close(): void;
}
