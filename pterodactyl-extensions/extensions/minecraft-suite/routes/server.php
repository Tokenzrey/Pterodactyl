<?php

use Illuminate\Support\Facades\Route;
use MinecraftSuite\Http\Controllers\HealthController;

// Mounted at /api/client/servers/{server}/extensions/minecraft-suite behind the Panel's server API stack. The
// Panel only proves the user may open the server: the controller checks ext.minecraft-suite.read itself.
Route::middleware('throttle:30,1,minecraft-suite-read')->get('/health', [HealthController::class, 'index']);
