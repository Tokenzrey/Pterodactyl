<?php

declare(strict_types=1);

namespace SubdomainManager\Rules;

use Closure;
use Illuminate\Contracts\Validation\DataAwareRule;
use Illuminate\Contracts\Validation\ValidationRule;
use SubdomainManager\Models\Record;

/**
 * The (domain, label) pair is not held by another server (FR-S2, AC-S10). A row of a server that is still
 * being cleaned up (`deleting`) holds its name until Cloudflare is clean, so the name cannot be handed on
 * while the old records may still exist.
 */
final class NameIsFree implements DataAwareRule, ValidationRule
{
    /** @var array<string, mixed> */
    private array $data = [];

    /** @param string|null $serverUuid the server being edited, whose own name does not count; null while creating */
    public function __construct(private readonly ?string $serverUuid) {}

    /** @param array<string, mixed> $data */
    public function setData(array $data): static
    {
        $this->data = $data;

        return $this;
    }

    public function validate(string $attribute, mixed $value, Closure $fail): void
    {
        $domain = $this->data['domain'] ?? null;
        if (! is_string($value) || $value === '' || ! is_string($domain) || $domain === '') {
            return; // the other rules report what is missing
        }

        $taken = Record::query()
            ->where('domain', strtolower($domain))
            ->where('label', $value)
            ->when($this->serverUuid, fn ($query, string $uuid) => $query->where('server_uuid', '!=', $uuid))
            ->exists();

        if ($taken) {
            $fail('This name is already used by another server.');
        }
    }
}
