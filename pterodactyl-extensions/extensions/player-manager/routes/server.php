<?php

use Illuminate\Support\Facades\Route;
use PlayerManager\Http\Controllers\PlayerController;

// Mounted at /api/client/servers/{server}/extensions/player-manager behind the Panel's server API stack. The
// Panel only proves the user may open the server: each controller method checks its own ext.player-manager.* key.
// Reading is cheap (and cached); a moderation action is not, so its limit is tighter (FR-PM17).
Route::middleware('throttle:30,1,player-manager-read')->get('/players', [PlayerController::class, 'index']);

Route::middleware('throttle:10,1,player-manager-action')->group(function (): void {
    Route::post('/players/{name}/kick', [PlayerController::class, 'kick']);
    Route::post('/players/{name}/ban', [PlayerController::class, 'ban']);
    Route::post('/players/{name}/op', [PlayerController::class, 'op']);
    Route::post('/players/{name}/deop', [PlayerController::class, 'deop']);
});
