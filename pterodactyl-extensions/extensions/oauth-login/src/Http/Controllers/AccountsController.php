<?php

declare(strict_types=1);

namespace OauthLogin\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Illuminate\Routing\Controller;
use OauthLogin\Models\Identity;
use OauthLogin\Support\OauthSettings;
use OauthLogin\Support\Provider;
use Pterodactyl\Facades\Activity;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

/**
 * What the "Connected accounts" page of the signed-in user needs: which providers can be connected, which are,
 * and a way to disconnect one. Only the user's own rows are ever read or removed; provider user ids and
 * credentials never leave the server.
 */
class AccountsController extends Controller
{
    public function index(Request $request, ExtensionSettingsRegistry $registry): JsonResponse
    {
        $settings = OauthSettings::fromRegistry($registry);
        $linked = Identity::query()->where('user_id', $request->user()->id)->get()->keyBy('provider');

        $providers = [];
        foreach (Provider::cases() as $provider) {
            $enabled = $settings->enabled($provider);
            $identity = $linked->get($provider->value);
            if (! $enabled && $identity === null) {
                continue; // nothing to connect and nothing to disconnect
            }

            $providers[] = [
                'id' => $provider->value,
                'label' => $provider->label(),
                'enabled' => $enabled,
                'linked' => $identity !== null,
                'linked_at' => $identity?->created_at?->toIso8601String(),
            ];
        }

        return response()->json(['providers' => $providers]);
    }

    public function destroy(Request $request, string $provider): Response
    {
        $provider = Provider::tryFrom($provider) ?? abort(404);
        $identity = Identity::query()->where('user_id', $request->user()->id)->where('provider', $provider->value)->first() ?? abort(404);

        $identity->delete();
        Activity::event('oauth-login:unlink')->subject($request->user())->property(['provider' => $provider->value])->withRequestMetadata()->log();

        return response()->noContent();
    }
}
