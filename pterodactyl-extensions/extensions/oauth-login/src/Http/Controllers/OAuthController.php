<?php

declare(strict_types=1);

namespace OauthLogin\Http\Controllers;

use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use OauthLogin\Support\AccountResolver;
use OauthLogin\Support\AuthUrl;
use OauthLogin\Support\Errors;
use OauthLogin\Support\Flow;
use OauthLogin\Support\OauthSettings;
use OauthLogin\Support\Provider;
use OauthLogin\Support\ProviderClient;
use OauthLogin\Support\ProviderException;
use OauthLogin\Support\RedirectUri;
use Pterodactyl\Contracts\Users\CompletesLogins;
use Pterodactyl\Facades\Activity;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

/**
 * The endpoints of the OAuth flow: sign in (`redirect`), connect an account while signed in (`link`) and the
 * shared `callback`. Every failure ends as a redirect carrying one fixed error code (to the login page when
 * signing in, to the account page when connecting); nothing from the request or the provider is echoed back.
 */
class OAuthController extends Controller
{
    /** How long a used state stays blocked. Longer than the flow lifetime, so a replay is always refused. */
    private const USED_STATE_TTL = Flow::TTL + 60;

    private const MAX_CODE_LENGTH = 2048;

    public function redirect(Request $request, ExtensionSettingsRegistry $registry, string $provider): RedirectResponse
    {
        $provider = Provider::tryFrom($provider) ?? abort(404);

        // Someone already signed in has nothing to do here (EC-O5).
        if (Auth::check()) {
            return redirect('/');
        }

        return $this->begin($request, $registry, $provider, null);
    }

    /** Starts a flow that attaches the provider account to the signed-in user instead of signing anyone in. */
    public function link(Request $request, ExtensionSettingsRegistry $registry, string $provider): RedirectResponse
    {
        $provider = Provider::tryFrom($provider) ?? abort(404);

        return $this->begin($request, $registry, $provider, (int) Auth::id());
    }

    public function callback(Request $request, ExtensionSettingsRegistry $registry, AccountResolver $accounts, ProviderClient $client, CompletesLogins $logins, string $provider): RedirectResponse
    {
        $provider = Provider::tryFrom($provider) ?? abort(404);

        // The flow leaves the session first, whatever happens next: a state works once (FR-O5).
        $state = $request->query('state');
        $flow = Flow::consume($request->session(), $provider, is_string($state) ? $state : '', now()->getTimestamp());
        if ($flow === null) {
            return $this->fail($provider, Errors::INVALID_STATE);
        }

        $linking = $flow->userId !== null;
        if (! $this->firstUse($flow) || ! $this->issuerMatches($request, $provider)) {
            return $this->fail($provider, Errors::INVALID_STATE, linking: $linking);
        }
        // A connect flow belongs to the user who started it. If the session now belongs to somebody else, or to nobody, stop here.
        if ($linking && Auth::id() !== $flow->userId) {
            return $this->fail($provider, Errors::INVALID_STATE, linking: Auth::check());
        }

        $settings = OauthSettings::fromRegistry($registry);
        $credentials = $settings->enabled($provider) ? $settings->credentials($provider) : null;
        if ($credentials === null) {
            return $this->fail($provider, Errors::PROVIDER_UNAVAILABLE, linking: $linking);
        }

        if ($request->query->has('error')) {
            return $this->fail($provider, $request->query('error') === 'access_denied' ? Errors::DENIED : Errors::PROVIDER_ERROR, linking: $linking);
        }

        $code = $request->query('code');
        if (! is_string($code) || $code === '' || strlen($code) > self::MAX_CODE_LENGTH) {
            return $this->fail($provider, Errors::PROVIDER_ERROR, linking: $linking);
        }

        try {
            $profile = $client->fetchProfile($provider, $credentials['id'], $credentials['secret'], $code, RedirectUri::for($provider), $flow->verifier);
        } catch (ProviderException $e) {
            return $this->fail($provider, $e->reason, $e->getMessage(), $linking);
        }

        if ($linking) {
            return $this->finishLink($request, $accounts, $provider, $profile);
        }

        $resolution = $accounts->resolve($provider, $profile, $settings);
        if ($resolution->user === null) {
            return $this->fail($provider, $resolution->error ?? Errors::REGISTRATION_FAILED);
        }

        $user = $resolution->user;
        if ($resolution->linked) {
            Activity::event($resolution->created ? 'oauth-login:register' : 'oauth-login:link')
                ->subject($user)->property(['provider' => $provider->value])->withRequestMetadata()->log();
        }

        // The policy has already refused every 2FA account unless the administrator trusts the provider.
        $user->use_totp ? $logins->establish($user) : $logins->complete($user);

        return redirect('/');
    }

    private function begin(Request $request, ExtensionSettingsRegistry $registry, Provider $provider, ?int $userId): RedirectResponse
    {
        $settings = OauthSettings::fromRegistry($registry);
        $credentials = $settings->enabled($provider) ? $settings->credentials($provider) : null;
        if ($credentials === null) {
            return $this->fail($provider, Errors::PROVIDER_UNAVAILABLE, linking: $userId !== null);
        }

        $flow = Flow::start($request->session(), $provider, now()->getTimestamp(), $userId);

        return redirect()->away(AuthUrl::build($provider, $credentials['id'], RedirectUri::for($provider), $flow));
    }

    private function finishLink(Request $request, AccountResolver $accounts, Provider $provider, \OauthLogin\Support\Profile $profile): RedirectResponse
    {
        $user = $request->user();
        $result = $accounts->attach($user, $provider, $profile);
        if ($result->error !== null) {
            return $this->fail($provider, $result->error, linking: true);
        }

        if ($result->linked) {
            Activity::event('oauth-login:link')->subject($user)->property(['provider' => $provider->value])->withRequestMetadata()->log();
        }

        return redirect(Errors::linkedUrl($provider));
    }

    /** Atomic across parallel requests; the session alone cannot be (sessions are not locked). */
    private function firstUse(Flow $flow): bool
    {
        return Cache::add('oauth-login:state:'.hash('sha256', $flow->state), true, self::USED_STATE_TTL);
    }

    /** RFC 9207: when the provider says who issued the response, it must be the provider we sent the user to. */
    private function issuerMatches(Request $request, Provider $provider): bool
    {
        $issuer = $provider->issuer();

        return $issuer === null || ! $request->query->has('iss') || $request->query('iss') === $issuer;
    }

    private function fail(Provider $provider, string $code, ?string $detail = null, bool $linking = false): RedirectResponse
    {
        // Provider, outcome and (for provider errors) a fixed description: never the code, state, token or an email address.
        Log::info('oauth-login: sign-in failed', array_filter(['provider' => $provider->value, 'error' => $code, 'detail' => $detail, 'mode' => $linking ? 'link' : null]));

        return redirect($linking ? Errors::accountUrl($code) : Errors::loginUrl($code));
    }
}
