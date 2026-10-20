<?php

use Illuminate\Support\Facades\Route;
use OauthLogin\Http\Controllers\OAuthController;

// Mounted at /extensions/oauth-login behind the Panel's signed-in web stack (session, 2FA requirement).
// Connects a provider account to the user who is signed in; the provider sends the browser back to the same
// callback as a sign-in, which tells the two apart by the flow it finds in the session.
Route::middleware('throttle:20,1,oauth-login')->get('/link/{provider}', [OAuthController::class, 'link'])->name('link');
