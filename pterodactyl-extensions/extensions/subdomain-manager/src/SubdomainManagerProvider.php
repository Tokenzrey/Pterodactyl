<?php

declare(strict_types=1);

namespace SubdomainManager;

use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Support\Facades\Event;
use Pterodactyl\Events\Server\OperationCompleted;
use Pterodactyl\Events\Server\Updated;
use Pterodactyl\Events\Server\Updating;
use Pterodactyl\Extensions\ExtensionProvider;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use SubdomainManager\Console\ReconcileCommand;
use SubdomainManager\Console\ResyncCommand;
use SubdomainManager\Fields\SubdomainFields;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Listeners\ServerRenamed;
use SubdomainManager\Listeners\ServerRenaming;
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
        $this->registerServerApiRoutes($this->extensionPath('routes', 'server.php'));

        // Admin settings form (Cloudflare token, domains, target IP, SRV, TTL, reserved labels).
        $this->registerSettings(SubdomainSettings::define($this->settings()));

        // The label and domain inputs on the admin server form.
        $this->registerFields(Server::class, SubdomainFields::class);

        // Safety net for jobs that never finished, every five minutes.
        $this->registerCommands([ReconcileCommand::class, ResyncCommand::class]);

        // Rename rules (FR-R9, FR-R10). Plain Event::listen, not listenToServerOperations: that one swallows exceptions,
        // and the refusal of a rename has to be an exception that stops the save.
        Event::listen(Updating::class, ServerRenaming::class);
        Event::listen(Updated::class, ServerRenamed::class);
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
