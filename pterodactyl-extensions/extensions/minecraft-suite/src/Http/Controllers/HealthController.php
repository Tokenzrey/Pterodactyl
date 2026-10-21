<?php

declare(strict_types=1);

namespace MinecraftSuite\Http\Controllers;

use Illuminate\Contracts\Cache\LockTimeoutException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use MinecraftSuite\Support\HealthParser;
use MinecraftSuite\Support\MinecraftSuiteSettings;
use MinecraftSuite\Support\RconClientFactory;
use MinecraftSuite\Support\RconException;
use MinecraftSuite\Support\TpsParser;
use Pterodactyl\Contracts\Servers\ReadsServerState;
use Pterodactyl\Data\ServerState;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionSettingsDefinition;

/**
 * TPS, MSPT and uptime of one server. The route checks its own permission (the Panel only proves the user may open
 * the server). RCON failures are answered with the fixed error codes and nothing of the server's own text; the
 * password never leaves the settings (FR-MS14, NFR-MS2).
 */
final class HealthController
{
    public function __construct(
        private readonly MinecraftSuiteSettings $settings,
        private readonly RconClientFactory $factory,
        private readonly ReadsServerState $state,
    ) {}

    public function index(Request $request, Server $server): JsonResponse
    {
        abort_unless($request->user()->can('ext.minecraft-suite.read', $server), 403);

        $settings = $this->settings->forServer($server);

        // Wings is asked through the Panel's own cached reader. When it cannot be reached the state is unknown:
        // RCON is tried anyway, and uptime is simply missing.
        $wings = $this->wings($server);
        if ($wings !== null && in_array($wings->state, ['offline', 'stopped'], true)) {
            return $this->answer(HealthParser::offline(), $settings);
        }

        $seconds = (int) ($settings->get('cache_seconds') ?? 3);
        $key = "minecraft-suite:health:{$server->id}";

        // One RCON call per window, shared by every viewer. Only good answers are cached (EC-MS9).
        if ($seconds > 0 && is_array($cached = Cache::get($key))) {
            return $this->answer($cached, $settings);
        }

        // Requests that miss the cache together take turns: the first asks the server, the others find its answer
        // in the cache once they get the lock (AC-MS9). Without the lock they would all call RCON.
        $lock = $seconds > 0 ? Cache::lock("{$key}:lock", 15) : null;

        try {
            $lock?->block(8);

            if ($lock !== null && is_array($cached = Cache::get($key))) {
                return $this->answer($cached, $settings);
            }

            $raw = $this->factory
                ->for((string) $settings->get('rcon_host'), (int) $settings->get('rcon_port'), (string) $settings->get('rcon_password'))
                ->command((string) ($settings->get('tps_command') ?: 'spark tps'));
        } catch (LockTimeoutException) {
            return $this->failure($server, new RconException(RconException::TIMEOUT, 'waited too long for the shared answer'));
        } catch (RconException $exception) {
            return $this->failure($server, $exception);
        } finally {
            $lock?->release();
        }

        $tps = TpsParser::parse($raw);
        if (! $tps['recognized']) {
            // Usually a wrong tps_command setting; the operator needs to see it. The answer itself is not logged.
            Log::warning('minecraft-suite: the TPS answer was not recognized', ['server' => $server->id]);
        }

        $health = HealthParser::build($tps, $wings?->uptime);
        if ($seconds > 0) {
            Cache::put($key, $health, $seconds);
        }

        return $this->answer($health, $settings);
    }

    /**
     * The health JSON, with the server's refresh interval beside it. It is a header, not a field, so the body stays
     * exactly the contract (FR-MS2). Held to 5 to 60 seconds whatever is stored (FR-MS9).
     *
     * @param  array<string, mixed>  $payload
     */
    private function answer(array $payload, ExtensionSettingsDefinition $settings): JsonResponse
    {
        $interval = (int) ($settings->get('poll_interval') ?: 10000);

        return response()->json($payload)->header('X-Poll-Interval', (string) max(5000, min(60000, $interval)));
    }

    private function failure(Server $server, RconException $exception): JsonResponse
    {
        // The code only: no server text, no password, no host (FR-MS14, NFR-MS7).
        Log::warning('minecraft-suite: RCON failed', ['server' => $server->id, 'code' => $exception->reason]);

        return response()->json(['error' => $exception->reason], 503);
    }

    private function wings(Server $server): ?ServerState
    {
        try {
            return $this->state->read($server);
        } catch (DaemonConnectionException) {
            return null;
        }
    }
}
