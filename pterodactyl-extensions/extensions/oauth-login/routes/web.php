<?php

use Illuminate\Support\Facades\Route;
use OauthLogin\Http\Controllers\OAuthController;

// Mounted at /extensions/oauth-login in the web group (session, cookies, CSRF for POST) and public:
// the visitor is not signed in yet. 20 requests a minute per client address (FR-O15).
// {provider} is not constrained here on purpose: an unknown value must reach the controller and end
// in a 404 (the Panel's catch-all would otherwise answer 200 with its React shell).
Route::middleware('throttle:20,1,oauth-login')->group(function (): void {
    Route::get('/redirect/{provider}', [OAuthController::class, 'redirect'])->name('redirect');
    Route::get('/callback/{provider}', [OAuthController::class, 'callback'])->name('callback');
});
