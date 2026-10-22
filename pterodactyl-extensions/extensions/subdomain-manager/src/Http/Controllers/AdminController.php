<?php

declare(strict_types=1);

namespace SubdomainManager\Http\Controllers;

use Illuminate\Http\Client\Factory;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use Pterodactyl\Models\Server;
use SubdomainManager\Models\Record;
use SubdomainManager\Support\CloudflareClient;
use SubdomainManager\Support\CloudflareException;
use SubdomainManager\Support\Labels;
use SubdomainManager\Support\SubdomainSettings;

/**
 * What the server form needs from the backend: which domains it may offer, and whether a name is free.
 * Mounted on the admin API, so only root administrators reach it. Neither answer carries the Cloudflare
 * token or a zone id (AC-S13).
 */
class AdminController extends Controller
{
    public function config(SubdomainSettings $settings): JsonResponse
    {
        return response()->json([
            'domains' => array_keys($settings->domains()),
            'srv_enabled' => $settings->srvEnabled(),
            'mode' => $settings->mode(),
            'reserved_labels' => $settings->reservedLabels(),
        ]);
    }

    /**
     * Checks the local database first, then Cloudflare. `exists_at_cloudflare` means a record with that name
     * exists there that this server does not own, which would make the sync fail with a conflict.
     */
    public function availability(Request $request, SubdomainSettings $settings, Factory $http): JsonResponse
    {
        $input = $request->validate([
            'domain' => ['required', 'string', 'max:253'],
            'label' => ['required', 'string', 'max:63'],
            'server' => ['nullable', 'integer', 'min:1'],
        ]);
        $domain = strtolower($input['domain']);
        $label = $input['label'];

        $zone = $settings->domains()[$domain] ?? null;
        if ($zone === null) {
            return $this->answer(false, 'unconfigured');
        }

        if (($problem = Labels::problem($label, $settings->reservedLabels())) !== null) {
            return $this->answer(false, $problem);
        }

        // The server being edited: its own row, if any, holds this name legitimately.
        $own = isset($input['server']) ? Record::query()->where('server_id', (int) $input['server'])->first() : null;

        $holder = Record::query()->where('domain', $domain)->where('label', $label)->first();
        if ($holder !== null && ($own === null || $holder->id !== $own->id)) {
            return $this->answer(false, 'taken');
        }
        if ($holder !== null && $own !== null && $holder->synced_name !== null) {
            return $this->answer(true, null); // already ours at Cloudflare; asking Cloudflare would only find our own records
        }

        $token = $settings->token();
        if ($token === null) {
            return $this->answer(true, null, checked: false);
        }

        try {
            $client = new CloudflareClient($http, $token);
            $name = Labels::fqdn($label, $domain);
            $exists = $client->findRecords($zone, 'A', $name) !== []
                || ($settings->srvEnabled() && $client->findRecords($zone, 'SRV', Labels::srvName($name)) !== []);
        } catch (CloudflareException) {
            // Cloudflare cannot be asked right now; the sync will check again before it creates anything.
            return $this->answer(true, null, checked: false);
        }

        return $exists ? $this->answer(false, 'exists_at_cloudflare') : $this->answer(true, null);
    }

    private function answer(bool $available, ?string $reason, bool $checked = true): JsonResponse
    {
        return response()->json(['available' => $available, 'reason' => $reason, 'checked_cloudflare' => $checked && $reason === null]);
    }
}
