<?php

declare(strict_types=1);

namespace SubdomainManager\Fields;

use Illuminate\Container\Attributes\CurrentUser;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;
use Pterodactyl\Extensions\Fields;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;
use SubdomainManager\Jobs\SyncRecord;
use SubdomainManager\Models\Record;
use SubdomainManager\Rules\NameIsFree;
use SubdomainManager\Rules\ValidLabel;
use SubdomainManager\Support\RoutedNames;
use SubdomainManager\Support\SubdomainSettings;

/**
 * The "subdomain" fields on the admin server form: a label and the domain it goes under.
 *
 * save() only writes what the administrator asked for (status `pending`) and schedules the Cloudflare job for
 * after the commit. It never talks to Cloudflare: that would hold the server transaction open on a network call
 * and let a Cloudflare outage block saving a server (FR-S3).
 */
final class SubdomainFields extends Fields
{
    /**
     * @return array<string, list<mixed>>
     */
    public function rules(?Server $server, SubdomainSettings $settings): array
    {
        // In routed mode the label is the slug of the server's name (FR-R2). save() sets it, and says why when it cannot.
        $label = $settings->mode() === 'routed'
            ? ['nullable', 'string']
            : ['nullable', 'string', new ValidLabel($settings->reservedLabels()), new NameIsFree($server?->uuid)];

        return [
            'label' => $label,
            'domain' => ['nullable', 'string', 'required_with:label', Rule::in(array_keys($settings->domains()))],
        ];
    }

    /** @return array<string, string> */
    public function attributes(): array
    {
        return ['label' => 'subdomain label', 'domain' => 'domain'];
    }

    /** @return array<string, string> */
    public function messages(): array
    {
        return [
            'domain.required_with' => 'Choose the domain the subdomain goes under.',
            'domain.in' => 'That domain is not one of the configured domains.',
        ];
    }

    /** Only root administrators may set subdomains (they decide who gets which name at the DNS provider). */
    public function authorize(#[CurrentUser] User $admin): bool
    {
        return (bool) $admin->root_admin;
    }

    /**
     * @return array<string, mixed>
     */
    public function values(Server $server): array
    {
        $record = Record::query()->where('server_uuid', $server->uuid)->first();
        $removing = $record?->status === Record::DELETING;
        $mode = SubdomainSettings::fromRegistry(app(ExtensionSettingsRegistry::class))->mode();
        // Scalars only: the Panel drops an extension's whole set of values when one of them is an array it does not know.
        $routing = RoutedNames::status($server, $mode);

        return [
            'label' => $record === null || $removing ? '' : $record->label,
            'domain' => $record === null || $removing ? '' : $record->domain,
            'status' => $record?->status,
            'fqdn' => $record === null || $removing ? null : $record->fqdn(),
            'error' => $record?->last_error,
            'mode' => $mode,
            'routing_state' => $routing['state'] ?? null,
            'routing_reason' => $routing['reason'] ?? null,
        ];
    }

    /** @param array{label?: string|null, domain?: string|null} $values */
    public function save(Server $server, SubdomainSettings $settings, array $values): void
    {
        $label = (string) ($values['label'] ?? '');
        $domain = strtolower((string) ($values['domain'] ?? ''));
        $record = Record::query()->where('server_uuid', $server->uuid)->first();

        if ($settings->mode() === 'routed' && $label !== '') {
            $label = $this->routedLabel($server); // whatever was typed: the name decides (FR-R2)
        }

        if ($label === '') {
            // An empty label removes the subdomain (FR-S1). Nothing to do when there never was one.
            if ($record !== null && $record->status !== Record::DELETING) {
                $record->update(['status' => Record::DELETING, 'last_error' => null, 'attempts' => 0]);
                $this->dispatchAfterCommit($record);
            }

            return;
        }

        try {
            if ($record === null) {
                $record = Record::query()->create([
                    'server_id' => $server->id,
                    'server_uuid' => $server->uuid,
                    'domain' => $domain,
                    'label' => $label,
                    'zone_id' => $settings->domains()[$domain] ?? str_repeat('0', 32),
                    'status' => Record::PENDING,
                ]);
            } elseif ($record->domain !== $domain || $record->label !== $label || $record->status !== Record::ACTIVE) {
                // A new name, or saving again to retry a failed one. Ids of records made for the old name stay on
                // the row: the job removes them by id before making the new ones (FR-S6).
                $record->update(['server_id' => $server->id, 'domain' => $domain, 'label' => $label, 'status' => Record::PENDING, 'last_error' => null, 'attempts' => 0]);
            } else {
                return;
            }
        } catch (UniqueConstraintViolationException) {
            // Two administrators chose the same name at the same moment (EC-S1): the second one loses, and the whole save rolls back.
            throw ValidationException::withMessages(['extensions.subdomain-manager.label' => 'This name is already used by another server.']);
        }

        $this->dispatchAfterCommit($record);
    }

    /**
     * Routed mode: the host name is the slug of the server's name, the same one `games sync` routes. Refused, with the
     * reason, when the name gives none, or when another Minecraft server already has that slug (FR-R6, EC-R1).
     */
    private function routedLabel(Server $server): string
    {
        $slug = RoutedNames::label($server);
        if ($slug === '') {
            throw ValidationException::withMessages(['extensions.subdomain-manager.label' => 'The server name does not give a host name. Use letters or digits in the name.']);
        }

        $other = RoutedNames::takenBy($server, $slug);
        if ($other !== null) {
            throw ValidationException::withMessages(['extensions.subdomain-manager.label' => "The host name $slug is already used by the server \"$other\"."]);
        }

        return $slug;
    }

    private function dispatchAfterCommit(Record $record): void
    {
        $id = $record->id;
        DB::afterCommit(fn () => SyncRecord::dispatchSafely($id));
    }
}
