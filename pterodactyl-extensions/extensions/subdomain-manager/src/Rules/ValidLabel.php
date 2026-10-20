<?php

declare(strict_types=1);

namespace SubdomainManager\Rules;

use Closure;
use Illuminate\Contracts\Validation\ValidationRule;
use SubdomainManager\Support\Labels;

/** The label is one DNS label in lower case and not on the reserved list (FR-S2, AC-S9). */
final readonly class ValidLabel implements ValidationRule
{
    /** @param list<string> $reserved */
    public function __construct(private array $reserved) {}

    public function validate(string $attribute, mixed $value, Closure $fail): void
    {
        if ($value === null || $value === '') {
            return; // empty means "no subdomain"
        }

        match (is_string($value) ? Labels::problem($value, $this->reserved) : 'invalid') {
            'invalid' => $fail('The label must be 1 to 63 lower-case letters, digits or hyphens, and cannot start or end with a hyphen.'),
            'reserved' => $fail('This label is reserved and cannot be used.'),
            default => null,
        };
    }
}
