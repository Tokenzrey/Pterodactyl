<?php

declare(strict_types=1);

namespace OauthLogin;

use OauthLogin\Support\OauthSettings;
use Pterodactyl\Extensions\ExtensionProvider;

class OauthLoginProvider extends ExtensionProvider
{
    public function boot(): void
    {
        // Public redirect/callback endpoints at /extensions/oauth-login/... (web group, no auth).
        $this->registerWebRoutes($this->extensionPath('routes', 'web.php'));

        // Connect a provider account to the signed-in user: GET /extensions/oauth-login/link/{provider}.
        $this->registerAuthenticatedWebRoutes($this->extensionPath('routes', 'account.php'));

        // The "Connected accounts" page: GET and DELETE /api/client/extensions/oauth-login/accounts.
        $this->registerClientApiRoutes($this->extensionPath('routes', 'client.php'));

        // Admin form, GET/PATCH /api/admin/extensions/oauth-login/settings, and the guest-readable
        // `enabled_providers` the login page uses to draw its buttons.
        $this->registerSettings(OauthSettings::define($this->settings()));
    }
}
