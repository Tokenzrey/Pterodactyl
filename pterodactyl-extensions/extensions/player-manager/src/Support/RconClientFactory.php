<?php

declare(strict_types=1);

namespace PlayerManager\Support;

use Closure;

/** Makes the RconClient for one server. The container rebinds it in tests so that no socket is ever opened. */
final class RconClientFactory
{
    /** @param  (Closure(string, int, float): RconConnection)|null  $open  null means a real TCP socket */
    public function __construct(private readonly ?Closure $open = null) {}

    /** @throws RconException rcon_not_configured when the host, port or password are not usable */
    public function for(string $host, int $port, string $password): RconClient
    {
        return new RconClient($host, $port, $password, $this->open);
    }
}
