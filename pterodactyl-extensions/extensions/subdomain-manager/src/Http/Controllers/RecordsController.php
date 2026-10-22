<?php

declare(strict_types=1);

namespace SubdomainManager\Http\Controllers;

use Illuminate\Http\Client\Factory;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Routing\Controller;
use Illuminate\Validation\Rule;
use Pterodactyl\Models\Server;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;
use SubdomainManager\Support\CloudflareClient;
use SubdomainManager\Support\CloudflareException;
use SubdomainManager\Support\RoutedNames;
use SubdomainManager\Support\SubdomainSettings;

/**
 * Everything the admin "Subdomains" page needs: is the setup complete, does the Cloudflare connection work, what
 * is in the table, and the two things an administrator can do to a row. Root administrators only (admin API).
 * No answer carries the token, a zone id or a Cloudflare record id.
 */
class RecordsController extends Controller
{
    private const PER_PAGE = 25;

    private const STATUSES = [Record::ACTIVE, Record::PENDING, Record::FAILED, Record::DELETING];

    public function overview(SubdomainSettings $settings): JsonResponse
    {
        $config = $settings->syncConfig();
        $counts = Record::query()->selectRaw('status, count(*) as total')->groupBy('status')->pluck('total', 'status');

        $byStatus = [];
        foreach (self::STATUSES as $status) {
            $byStatus[$status] = (int) ($counts[$status] ?? 0);
        }

        return response()->json([
            'setup' => [
                'token' => $settings->token() !== null,
                'domains' => count($config->domains),
                'target_ip' => filter_var($config->targetIpv4, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false,
                'srv_enabled' => $config->srvEnabled,
            ],
            'counts' => [...$byStatus, 'total' => array_sum($byStatus)],
        ]);
    }

    /** Reads one record from every configured zone: proves the token works and can see each zone. */
    public function test(SubdomainSettings $settings, Factory $http): JsonResponse
    {
        $token = $settings->token();
        $domains = $settings->domains();
        if ($token === null || $domains === []) {
            return response()->json(['problem' => $token === null ? 'token' : 'domains', 'results' => []]);
        }

        $client = new CloudflareClient($http, $token);
        $results = [];
        foreach ($domains as $domain => $zone) {
            try {
                $client->ping($zone);
                $results[] = ['domain' => $domain, 'ok' => true, 'message' => null];
            } catch (CloudflareException $e) {
                $results[] = ['domain' => $domain, 'ok' => false, 'message' => $e->safe];
            }
        }

        return response()->json(['problem' => null, 'results' => $results]);
    }

    public function index(Request $request, SubdomainSettings $settings): JsonResponse
    {
        $input = $request->validate([
            'status' => ['nullable', 'string', Rule::in(self::STATUSES)],
            'q' => ['nullable', 'string', 'max:100'],
            'page' => ['nullable', 'integer', 'min:1'],
        ]);

        $query = Record::query()->orderByDesc('updated_at')->orderByDesc('id');
        if (! empty($input['status'])) {
            $query->where('status', $input['status']);
        }
        if (! empty($input['q'])) {
            // % and _ are ordinary characters in a search box.
            $like = '%'.str_replace(['\\', '%', '_'], ['\\\\', '\\%', '\\_'], strtolower($input['q'])).'%';
            $query->where(fn ($inner) => $inner->whereRaw("lower(concat(label, '.', domain)) like ?", [$like]));
        }

        $page = $query->paginate(self::PER_PAGE, page: (int) ($input['page'] ?? 1));
        $servers = Server::query()->with(['egg', 'allocation'])->whereIn('id', $page->pluck('server_id')->filter()->all())->get()->keyBy('id');
        $mode = $settings->mode();

        return response()->json([
            'data' => $page->getCollection()->map(function (Record $record) use ($servers, $mode): array {
                $server = $record->server_id !== null ? $servers->get($record->server_id) : null;

                return [
                    'id' => $record->id,
                    'label' => $record->label,
                    'domain' => $record->domain,
                    'address' => $record->fqdn(),
                    'status' => $record->status,
                    'last_error' => $record->last_error,
                    'attempts' => $record->attempts,
                    'server' => $server !== null ? ['id' => $server->id, 'name' => $server->name] : null,
                    // Whether games sync routes that server's name (FR-R5). Null in per-port mode, and for a deleted server.
                    'routing' => $server !== null ? RoutedNames::status($server, $mode) : null,
                    'updated_at' => $record->updated_at?->toIso8601String(),
                ];
            })->values(),
            'meta' => ['page' => $page->currentPage(), 'pages' => max(1, $page->lastPage()), 'total' => $page->total()],
        ]);
    }

    /** Try a stuck row again. Active rows have nothing to retry. */
    public function retry(string $id): JsonResponse
    {
        $record = $this->find($id);
        if ($record->status === Record::ACTIVE) {
            return response()->json(['message' => 'This subdomain is already active; there is nothing to retry.'], 409);
        }

        if ($record->status !== Record::DELETING) {
            $record->update(['status' => Record::PENDING, 'last_error' => null, 'attempts' => 0]);
        }
        SyncRecord::dispatchSafely($record->id);

        return $this->state($record->refresh(), 202);
    }

    /** Take a subdomain away: the Cloudflare records are deleted (by id) and then the row. */
    public function remove(string $id): JsonResponse
    {
        $record = $this->find($id);
        if ($record->status !== Record::DELETING) {
            $record->update(['status' => Record::DELETING, 'last_error' => null, 'attempts' => 0]);
        }
        SyncRecord::dispatchSafely($record->id);

        return $this->state(Record::query()->find($record->id) ?? $record, 202);
    }

    private function find(string $id): Record
    {
        return ctype_digit($id) ? Record::query()->findOrFail((int) $id) : abort(404);
    }

    private function state(Record $record, int $status): JsonResponse
    {
        return response()->json(['id' => $record->id, 'status' => $record->status], $status);
    }
}
