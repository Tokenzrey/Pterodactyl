<?php

use Illuminate\Support\Facades\Route;
use ModpackInstaller\Http\Controllers\DefaultsController;
use ModpackInstaller\Http\Controllers\InstallController;
use ModpackInstaller\Http\Controllers\SearchController;

Route::middleware('throttle:30,1,modpack-installer')->group(function (): void {
    Route::get('/search', [SearchController::class, 'search'])->name('search');
    Route::post('/install', [InstallController::class, 'install'])->name('install');
    Route::get('/defaults', [DefaultsController::class, 'show'])->name('defaults.show');
    Route::put('/defaults', [DefaultsController::class, 'update'])->name('defaults.update');
});
