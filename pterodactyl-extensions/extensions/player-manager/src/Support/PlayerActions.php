<?php

declare(strict_types=1);

namespace PlayerManager\Support;

use InvalidArgumentException;

/**
 * The four moderation commands, sent over RCON. The name is checked against the Minecraft name rules before it
 * is put in a command, which is what keeps a player name from becoming a second command (T-PM1). Nothing from
 * the server's answer is returned: the caller learns only that the command was sent.
 */
final class PlayerActions
{
    private const MAX_REASON = 256;

    public function __construct(private readonly RconClient $rcon) {}

    public function kick(string $name, ?string $reason = null): void
    {
        $this->send('kick', $name, $reason);
    }

    public function ban(string $name, ?string $reason = null): void
    {
        $this->send('ban', $name, $reason);
    }

    public function op(string $name): void
    {
        $this->send('op', $name);
    }

    public function deop(string $name): void
    {
        $this->send('deop', $name);
    }

    private function send(string $verb, string $name, ?string $reason = null): void
    {
        // \A and \z, not ^ and $: a trailing newline must not pass as the end of the name.
        if (preg_match('/\A[a-zA-Z0-9_]{3,16}\z/', $name) !== 1) {
            throw new InvalidArgumentException('The player name is not a valid Minecraft name.');
        }

        $this->rcon->command(trim("{$verb} {$name} ".self::reason($reason)));
    }

    /** Printable ASCII only, at most 256 characters: nothing a console could read as a line break or a separator. */
    private static function reason(?string $reason): string
    {
        if ($reason === null) {
            return '';
        }

        return substr((string) preg_replace('/[^\x20-\x7E]/', '', $reason), 0, self::MAX_REASON);
    }
}
