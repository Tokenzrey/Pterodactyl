<?php

declare(strict_types=1);

namespace SubdomainManager\Support;

use Pterodactyl\Models\Server;
use SubdomainManager\Models\Record;

/**
 * Brings Cloudflare in line with one Record row. Every Cloudflare call in the extension happens here, and
 * every step writes its result (the record ids) to the database before the next one starts, so a run that
 * dies half way is simply run again: ids already stored are reused, never created twice (FR-S4, EC-S9).
 *
 * Records are only ever deleted by the ids stored in the row, and only records this extension created are
 * ever touched: a record that is already there under the wanted name is a conflict, never overwritten (FR-S5).
 */
final class RecordSyncer
{
    /** @param CloudflareClient|null $cf null while no Cloudflare token is configured */
    public function __construct(private readonly ?CloudflareClient $cf, private readonly SyncConfig $config) {}

    /**
     * Retryable Cloudflare failures are recorded on the row and thrown again, for the queue to retry with a
     * pause. Anything else ends in status `failed` (or, for a server being deleted, stays `deleting`).
     *
     * @throws CloudflareException when a retry could help
     */
    public function sync(Record $record): void
    {
        try {
            match ($record->status) {
                Record::DELETING => $this->tearDown($record),
                Record::PENDING, Record::FAILED => $this->build($record),
                Record::ACTIVE => $this->srvDrifts($record) ? $this->build($record) : null,
                default => null,
            };
        } catch (CloudflareException $e) {
            $record->attempts = min(255, $record->attempts + 1);
            $record->last_error = $e->safe;
            if (! $e->retryable && $record->status !== Record::DELETING) {
                $record->status = Record::FAILED;
            }
            $record->save();

            if ($e->retryable) {
                throw $e;
            }
        }
    }

    private function build(Record $record): void
    {
        if (! $this->cf instanceof CloudflareClient) {
            $this->fail($record, 'config: the Cloudflare token is not set');

            return;
        }
        if (($problem = $this->config->problem($record->domain)) !== null) {
            $this->fail($record, 'config: '.$problem);

            return;
        }

        $zone = (string) $this->config->zoneFor($record->domain);
        $name = $record->fqdn();

        // Label or domain changed since the records were made: remove those, by id, before making new ones (FR-S6).
        if ($record->synced_name !== null && ($record->synced_name !== $name || $record->zone_id !== $zone)) {
            $this->deleteStored($record);
        }

        if ($this->config->routed) {
            // Routed mode makes no A record for the server: the router answers for the name (FR-R3). A name that already
            // has an A record which is not ours still conflicts, because it would take the name away from the router.
            // That is checked once, when the name is first used; later syncs of the same name make no call here.
            if ($record->a_record_id === null && $record->synced_name === null && ! $this->isFree($zone, 'A', $name)) {
                $this->fail($record, $this->conflict($name));

                return;
            }
            $record->zone_id = $zone;
            $record->synced_name = $name;
            $record->save();
        } elseif ($record->a_record_id === null) {
            if (! $this->isFree($zone, 'A', $name)) {
                $this->fail($record, $this->conflict($name));

                return;
            }
            $record->a_record_id = $this->cf->createRecord($zone, Payloads::a($name, $this->config->targetIpv4, $this->config->ttl, $record->server_uuid));
            $record->zone_id = $zone;
            $record->synced_name = $name;
            $record->save();
        }

        $note = $this->syncSrv($record, $zone, $name);
        if ($note === false) {
            return;
        }

        $record->status = Record::ACTIVE;
        $record->last_error = $note;
        $record->attempts = 0;
        $record->save();
    }

    /** @return string|null|false a note for the admin, null for none, or false when the row was failed (a conflict) */
    private function syncSrv(Record $record, string $zone, string $name): string|null|false
    {
        if (! $this->config->srvEnabled) {
            $this->deleteSrv($record);

            return null;
        }

        $port = $this->srvPortFor($record);
        if ($port === null) {
            return 'SRV record skipped: the server has no primary allocation to take the port from';
        }

        // A different port (a mode switch, or a fixed port that changed): the old record goes first, by its stored id.
        // Creating the new one first would leave the old one behind with its old port if removing it failed, and
        // nothing would know its id any more (FR-R8).
        if ($record->srv_record_id !== null && $record->srv_port !== $port) {
            $this->deleteSrv($record);
        }

        if ($record->srv_record_id === null) {
            $srvName = Labels::srvName($name);
            if (! $this->isFree($zone, 'SRV', $srvName)) {
                $this->fail($record, $this->conflict($srvName));

                return false;
            }
            $record->srv_record_id = $this->cf->createRecord($zone, Payloads::srv($srvName, $name, $port, $this->config->ttl));
            $record->srv_port = $port;
            $record->save();
        }

        return null;
    }

    private function tearDown(Record $record): void
    {
        if (! $record->hasCloudflareRecords()) {
            $record->delete(); // never reached Cloudflare (EC-S5), or already cleaned up

            return;
        }
        if (! $this->cf instanceof CloudflareClient) {
            $record->last_error = 'config: the Cloudflare token is not set, so the DNS records cannot be removed yet';
            $record->save();

            return;
        }

        $this->deleteStored($record);
        $record->delete();
    }

    /** Deletes the stored ids, SRV first, saving after each so a failure half way keeps what is left. */
    private function deleteStored(Record $record): void
    {
        $this->deleteSrv($record);

        if ($record->a_record_id !== null) {
            $this->cf->deleteRecord($record->zone_id, $record->a_record_id);
            $record->a_record_id = null;
            $record->save();
        }

        $record->synced_name = null;
        $record->save();
    }

    private function deleteSrv(Record $record): void
    {
        if ($record->srv_record_id !== null) {
            $this->cf->deleteRecord($record->zone_id, $record->srv_record_id);
            $record->srv_record_id = null;
            $record->srv_port = null;
            $record->save();
        }
    }

    /** True when Cloudflare has no record of that type and name at all: we adopt nothing and overwrite nothing. */
    private function isFree(string $zone, string $type, string $name): bool
    {
        return $this->cf->findRecords($zone, $type, $name) === [];
    }

    private function conflict(string $name): string
    {
        return 'conflict: Cloudflare already has a record named '.$name.' that this extension did not create; remove it there or pick another label';
    }

    /** The port the SRV record should carry now: the fixed one when set, otherwise the server's own allocation. */
    private function srvPortFor(Record $record): ?int
    {
        return $this->config->srvPort > 0 ? $this->config->srvPort : $this->allocationPort($record);
    }

    /** An active row whose SRV record is on another port than the settings want (a mode switch, a changed port). */
    private function srvDrifts(Record $record): bool
    {
        if ($record->srv_record_id === null || ! $this->config->srvEnabled) {
            return false;
        }
        $port = $this->srvPortFor($record);

        return $port !== null && $port !== $record->srv_port;
    }

    private function allocationPort(Record $record): ?int
    {
        $port = $record->server_id === null ? null : Server::query()->with('allocation')->find($record->server_id)?->allocation?->port;

        return is_int($port) && $port > 0 ? $port : null;
    }

    private function fail(Record $record, string $message): void
    {
        $record->status = $record->status === Record::DELETING ? Record::DELETING : Record::FAILED;
        $record->last_error = mb_substr($message, 0, 255);
        $record->save();
    }
}
