<?php

use Illuminate\Support\Facades\Route;
use SubdomainManager\Http\Controllers\AdminController;
use SubdomainManager\Http\Controllers\RecordsController;

// Mounted at /api/admin/extensions/subdomain-manager behind the Panel's admin API stack (root administrators
// only). Anything that spends Cloudflare API calls (the form's availability check, the connection test) has its
// own, tighter limit; plain reads of the local table have a looser one.
Route::middleware('throttle:30,1,subdomain-manager')->group(function (): void {
    Route::get('/config', [AdminController::class, 'config'])->name('config');
    Route::get('/availability', [AdminController::class, 'availability'])->name('availability');
    Route::post('/test', [RecordsController::class, 'test'])->name('test');
});

Route::middleware('throttle:120,1,subdomain-manager-read')->group(function (): void {
    Route::get('/overview', [RecordsController::class, 'overview'])->name('overview');
    Route::get('/records', [RecordsController::class, 'index'])->name('records');
    Route::post('/records/{id}/retry', [RecordsController::class, 'retry'])->name('records.retry');
    Route::delete('/records/{id}', [RecordsController::class, 'remove'])->name('records.remove');
});
