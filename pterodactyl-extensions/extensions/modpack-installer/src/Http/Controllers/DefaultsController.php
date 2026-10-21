<?php

declare(strict_types=1);

namespace ModpackInstaller\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use ModpackInstaller\Support\ServerDefaults;
use Pterodactyl\Models\Server;

/** Reads and saves what a server's search opens with (plan 12, "Pengaturan per-server"). Needs the install permission. */
final class DefaultsController extends Controller
{
    public function show(Request $request, Server $server): JsonResponse
    {
        abort_unless($request->user()->can('ext.modpack-installer.install', $server), 403);

        return response()->json(ServerDefaults::values(ServerDefaults::for($server)));
    }

    public function update(Request $request, Server $server): JsonResponse
    {
        abort_unless($request->user()->can('ext.modpack-installer.install', $server), 403);

        $defaults = ServerDefaults::for($server);
        $input = $request->validate($defaults->validationRules());

        $defaults->update($input);

        return response()->json(ServerDefaults::values($defaults));
    }
}
