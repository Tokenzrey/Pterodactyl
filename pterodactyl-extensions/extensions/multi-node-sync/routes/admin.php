<?php

use Illuminate\Support\Facades\Route;
use MultiNodeSync\Http\Controllers\MigrationController;
use MultiNodeSync\Http\Controllers\S3Controller;

Route::middleware('throttle:20,1,multi-node-sync')->group(function (): void {
    Route::post('/s3/presign', [S3Controller::class, 'presign'])->name('s3.presign');
    Route::get('/s3/config', [S3Controller::class, 'config'])->name('s3.config');

    Route::post('/migrations', [MigrationController::class, 'create'])->name('migrations.create');
    Route::post('/migrations/{id}/confirm', [MigrationController::class, 'confirm'])->name('migrations.confirm');
    Route::get('/migrations', [MigrationController::class, 'index'])->name('migrations.index');
    Route::get('/migrations/{id}', [MigrationController::class, 'show'])->name('migrations.show');
    Route::delete('/migrations/{id}', [MigrationController::class, 'cancel'])->name('migrations.cancel');
});
