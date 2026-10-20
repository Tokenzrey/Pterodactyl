<?php

declare(strict_types=1);

namespace SubdomainManager;

use Illuminate\Console\Scheduling\Schedule;
use Pterodactyl\Events\Server\OperationCompleted;
use Pterodactyl\Extensions\ExtensionProvider;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use SubdomainManager\Console\ReconcileCommand;
use SubdomainManager\Fields\SubdomainFields;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;
use SubdomainManager\Support\SubdomainSettings;

class SubdomainManagerProvider extends ExtensionProvider
{
    public function register(): void
    {
        // Lets Fields methods and controllers type-hint the settings.
        $this->app->bind(SubdomainSettings::class, fn ($app): SubdomainSettings => SubdomainSettings::fromRegistry($app->make(ExtensionSettingsRegistry::class)));
    }

    public function boot(): void
    {
        // GET /api/admin/extensions/subdomain-manager/{config,availability}, root administrators only.
        $this->registerAdminApiRoutes($this->extensionPath('routes', 'admin.php'));

        // Admin settings form (Cloudflare token, domains, target IP, SRV, TTL, reserved labels).
        $this->registerSettings(SubdomainSettings::define($this->settings()));

        // The label and domain inputs on the admin server form.
        $this->registerFields(Server::class, SubdomainFields::class);

        // Safety net for jobs that never finished, every five minutes.
        $this->registerCommands([ReconcileCommand::class]);
        $this->registerSchedule(fn (Schedule $schedule) => $schedule->command('subdomain-manager:reconcile')->everyFiveMinutes()->withoutOverlapping());

        // A deleted server's DNS records go too (FR-S7). The row is marked first, so the cleanup survives a Cloudflare outage.
        $this->listenToServerOperations(function (OperationCompleted $event): void {
            if ($event->operation !== 'delete' || ! $event->successful) {
                return;
            }

            $record = Record::query()->where('server_uuid', $event->serverUuid)->first();
            if ($record === null) {
                return;
            }

            $record->update(['server_id' => null, 'status' => Record::DELETING, 'last_error' => null, 'attempts' => 0]);
            SyncRecord::dispatchSafely($record->id);
        });
    }
}
