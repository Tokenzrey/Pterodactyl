<?php

use Illuminate\Support\Facades\Route;
use SubdomainManager\Http\Controllers\AddressController;

// Mounted at /api/client/servers/{server}/extensions/subdomain-manager behind the Panel's server API stack: the Panel
// has already proved the user may open this server. The address is not secret, so no extra permission is asked for.
Route::middleware('throttle:240,1,subdomain-manager-address')->get('/address', [AddressController::class, 'show'])->name('address');
