<?php

declare(strict_types=1);

namespace PlayerManager\Http\Controllers;

use Closure;
use Illuminate\Contracts\Cache\LockTimeoutException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use InvalidArgumentException;
use PlayerManager\Support\PlayerActions;
use PlayerManager\Support\PlayerListParser;
use PlayerManager\Support\PlayerManagerSettings;
use PlayerManager\Support\RconClient;
use PlayerManager\Support\RconClientFactory;
use PlayerManager\Support\RconException;
use Pterodactyl\Contracts\Servers\ReadsServerState;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;

/**
 * The players endpoint and the four moderation actions of one server. Every route checks its own permission
 * (the Panel only proves the user may open the server). RCON failures are answered with the fixed error codes
 * and nothing of the server's own text; the password never leaves the settings (FR-PM18, NFR-PM2).
 */
final class PlayerController
{
    public function __construct(
        private readonly PlayerManagerSettings $settings,
        private readonly RconClientFactory $factory,
        private readonly ReadsServerState $state,
    ) {}

    public function index(Request $request, Server $server): JsonResponse
    {
        abort_unless($request->user()->can('ext.player-manager.read', $server), 403);

        $settings = $this->settings->forServer($server);

        // A server that is off has nobody online and nothing listening on RCON (FR-PM5). Wings is asked through the
        // Panel's own cached reader; when Wings cannot be reached the state is unknown, and RCON is tried anyway.
        if ($this->isOff($server)) {
            return $this->answer(['online_count' => 0, 'max_count' => null, 'players' => []], $settings);
        }

        $seconds = (int) ($settings->get('cache_seconds') ?? 3);
        $key = "player-manager:players:{$server->id}";

        // One RCON call per window, shared by every viewer. Only good answers are cached (EC-PM11).
        if ($seconds > 0 && is_array($cached = Cache::get($key))) {
            return $this->answer($cached, $settings);
        }

        // Requests that miss the cache together take turns: the first asks the server, the others find its answer
        // in the cache once they get the lock (AC-PM13). Without the lock they would all call RCON.
        $lock = $seconds > 0 ? Cache::lock("{$key}:lock", 15) : null;

        try {
            $lock?->block(8);

            if ($lock !== null && is_array($cached = Cache::get($key))) {
                return $this->answer($cached, $settings);
            }

            $raw = $this->client($settings)->command((string) ($settings->get('list_command') ?: 'playermanager:players'));
        } catch (LockTimeoutException) {
            return $this->failure($server, new RconException(RconException::TIMEOUT, 'waited too long for the shared answer'));
        } catch (RconException $exception) {
            return $this->failure($server, $exception);
        } finally {
            $lock?->release();
        }

        $parsed = PlayerListParser::parse($raw);
        if (! $parsed['recognized']) {
            // Usually a wrong list_command setting; the operator needs to see it. The answer itself is not logged.
            Log::warning('player-manager: the player list answer was not recognized', ['server' => $server->id]);
        }
        unset($parsed['recognized']);

        if ($seconds > 0) {
            Cache::put($key, $parsed, $seconds);
        }

        return $this->answer($parsed, $settings);
    }

    public function kick(Request $request, Server $server, string $name): JsonResponse
    {
        return $this->act($request, $server, 'kick', ['kicked' => true], fn (PlayerActions $actions) => $actions->kick($name, $request->input('reason')), $name, true);
    }

    public function ban(Request $request, Server $server, string $name): JsonResponse
    {
        return $this->act($request, $server, 'ban', ['banned' => true], fn (PlayerActions $actions) => $actions->ban($name, $request->input('reason')), $name, true);
    }

    public function op(Request $request, Server $server, string $name): JsonResponse
    {
        return $this->act($request, $server, 'op', ['op' => true], fn (PlayerActions $actions) => $actions->op($name), $name);
    }

    public function deop(Request $request, Server $server, string $name): JsonResponse
    {
        return $this->act($request, $server, 'deop', ['op' => false], fn (PlayerActions $actions) => $actions->deop($name), $name);
    }

    /**
     * @param  array<string, bool>  $answer
     * @param  Closure(PlayerActions): void  $run
     */
    private function act(Request $request, Server $server, string $permission, array $answer, Closure $run, string $name, bool $withReason = false): JsonResponse
    {
        abort_unless($request->user()->can("ext.player-manager.{$permission}", $server), 403);

        if ($withReason) {
            $request->validate(['reason' => ['nullable', 'string', 'max:256']]);
        }

        try {
            $run(new PlayerActions($this->client($this->settings->forServer($server))));
        } catch (InvalidArgumentException) {
            return response()->json(['error' => 'invalid_player_name'], 422);
        } catch (RconException $exception) {
            return $this->failure($server, $exception);
        }

        Log::info('player-manager: moderation action', ['server' => $server->id, 'action' => $permission, 'player' => $name]);

        return response()->json($answer);
    }

    /**
     * The players JSON, with the server's refresh interval beside it. It is a header, not a field, so the body
     * stays exactly the contract (FR-PM2). Held to 5 to 60 seconds whatever is stored (FR-PM13).
     *
     * @param  array<string, mixed>  $payload
     */
    private function answer(array $payload, ExtensionSettingsDefinition $settings): JsonResponse
    {
        $interval = (int) ($settings->get('poll_interval') ?: 10000);

        return response()->json($payload)->header('X-Poll-Interval', (string) max(5000, min(60000, $interval)));
    }

    private function isOff(Server $server): bool
    {
        try {
            return in_array($this->state->read($server)->state, ['offline', 'stopped'], true);
        } catch (DaemonConnectionException) {
            return false;
        }
    }

    /** @throws RconException rcon_not_configured when the server has no usable RCON settings */
    private function client(ExtensionSettingsDefinition $settings): RconClient
    {
        return $this->factory->for(
            (string) $settings->get('rcon_host'),
            (int) $settings->get('rcon_port'),
            (string) $settings->get('rcon_password'),
        );
    }

    private function failure(Server $server, RconException $exception): JsonResponse
    {
        // The code only: no server text, no password, no host (FR-PM18, NFR-PM8).
        Log::warning('player-manager: RCON failed', ['server' => $server->id, 'code' => $exception->reason]);

        return response()->json(['error' => $exception->reason], 503);
    }
}
