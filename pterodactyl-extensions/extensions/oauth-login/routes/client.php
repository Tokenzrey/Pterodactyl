<?php

use Illuminate\Support\Facades\Route;
use OauthLogin\Http\Controllers\AccountsController;

// Mounted at /api/client/extensions/oauth-login (signed-in users, the Panel's client API stack).
Route::get('/accounts', [AccountsController::class, 'index'])->name('accounts');
Route::delete('/accounts/{provider}', [AccountsController::class, 'destroy'])->name('accounts.destroy');
