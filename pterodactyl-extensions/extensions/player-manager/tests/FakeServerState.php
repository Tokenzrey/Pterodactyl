<?php

declare(strict_types=1);

namespace PlayerManager\Tests;

use Pterodactyl\Contracts\Servers\ReadsServerState;
use Pterodactyl\Data\ServerState;
use Pterodactyl\Models\Server;
use Throwable;

/** What Wings says about a server's power state, without Wings. Set a Throwable to make Wings unreachable. */
final class FakeServerState implements ReadsServerState
{
    public int $reads = 0;

    public function __construct(public string|Throwable $result = 'running') {}

    public function read(Server $server): ServerState
    {
        $this->reads++;

        if ($this->result instanceof Throwable) {
            throw $this->result;
        }

        return new ServerState($this->result, false, 0, 0, 0, 0, 0, 0);
    }
}
