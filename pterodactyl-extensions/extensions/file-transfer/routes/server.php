<?php

use FileTransfer\Http\Controllers\ChunkController;
use FileTransfer\Http\Controllers\RemoteFetchController;
use Illuminate\Support\Facades\Route;

// Mounted at /api/client/servers/{server}/extensions/file-transfer behind the Panel's server API stack. The Panel
// only proves the user may open the server: each controller checks its own permission. The limit is per user (FR-FT18).
Route::middleware('throttle:30,1,file-transfer')->group(function (): void {
    Route::post('/chunk', [ChunkController::class, 'chunk']);
    Route::post('/chunk/merge', [ChunkController::class, 'merge']);
    Route::post('/remote-fetch', [RemoteFetchController::class, 'fetch']);
});
