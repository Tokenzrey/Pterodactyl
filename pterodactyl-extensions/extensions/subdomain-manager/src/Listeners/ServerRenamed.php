<?php

declare(strict_types=1);

namespace SubdomainManager\Listeners;

use Illuminate\Support\Facades\DB;
use Pterodactyl\Events\Server\Updated;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;
use SubdomainManager\Support\RoutedNames;
use SubdomainManager\Support\SubdomainSettings;

/**
 * After a rename is saved (FR-R9): the label follows the new name and the records are sent again. The records of the
 * old name are removed by their stored ids, by the syncer, which sees that the label and the name no longer agree.
 */
final class ServerRenamed
{
    public function __construct(private readonly ExtensionSettingsRegistry $registry) {}

    public function handle(Updated $event): void
    {
        $server = $event->server;
        if (! $server->wasChanged('name') || ! RoutedNames::isMinecraft($server) || ! $this->routed()) {
            return;
        }

        $record = Record::query()->where('server_uuid', $server->uuid)->first();
        if ($record === null || $record->status === Record::DELETING) {
            return;
        }

        $label = RoutedNames::label($server);
        if ($label === '' || $label === $record->label) {
            return;
        }

        $record->update(['label' => $label, 'status' => Record::PENDING, 'last_error' => null, 'attempts' => 0]);

        $id = $record->id;
        DB::afterCommit(fn () => SyncRecord::dispatchSafely($id));
    }

    private function routed(): bool
    {
        return SubdomainSettings::fromRegistry($this->registry)->mode() === 'routed';
    }
}
