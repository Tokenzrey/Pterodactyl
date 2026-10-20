/** Same rule as the backend (SubdomainManager\Support\Labels): lower case, digits, inner hyphens, 1 to 63 characters. */
export const LABEL_PATTERN = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;

export type LocalProblem = 'invalid' | 'reserved';

/** What can be said about a label without asking the server. Empty is not a problem: it means "no subdomain". */
export function labelProblem(label: string, reserved: readonly string[]): LocalProblem | null {
    if (label === '') {
        return null;
    }
    if (!LABEL_PATTERN.test(label)) {
        return 'invalid';
    }

    return reserved.some((entry) => entry.toLowerCase() === label) ? 'reserved' : null;
}

export function fqdn(label: string, domain: string): string {
    return `${label}.${domain}`.toLowerCase();
}

export const REASON_TEXT = {
    invalid: 'Use 1 to 63 lower-case letters, digits or hyphens, not starting or ending with a hyphen.',
    reserved: 'This name is reserved.',
    taken: 'Another server already uses this name.',
    exists_at_cloudflare: 'A DNS record with this name already exists at Cloudflare and was not made by this panel. Delete it there, or choose another label.',
    unconfigured: 'Choose one of the configured domains.',
} as const;

export type Reason = keyof typeof REASON_TEXT;

export type Status = 'active' | 'pending' | 'failed' | 'deleting';
export const STATUSES: readonly Status[] = ['active', 'pending', 'failed', 'deleting'];

export function isStatus(value: unknown): value is Status {
    return STATUSES.some((status) => status === value);
}

/** How each state of a subdomain is named and explained. `tone` is one of the panel's badge tones. */
export const STATUS_META: Record<Status, { text: string; tone: 'success' | 'neutral' | 'danger' | 'warning'; help: string }> = {
    active: { text: 'Active', tone: 'success', help: 'The DNS records exist. Players can use this address.' },
    pending: { text: 'Waiting for Cloudflare', tone: 'neutral', help: 'Saved. The DNS records are made in the background, usually within a minute.' },
    failed: { text: 'Failed', tone: 'danger', help: 'The DNS records could not be made. Fix the cause, then save again to retry.' },
    deleting: { text: 'Being removed', tone: 'warning', help: 'The DNS records are being deleted at Cloudflare.' },
};

/** What to do about the error a failed sync left. The error text itself is shown as it is. */
export function errorAdvice(error: string | null): string | null {
    if (!error) {
        return null;
    }
    if (error.startsWith('conflict:')) {
        return 'Delete that record at Cloudflare, or choose another label.';
    }
    if (error.startsWith('config:')) {
        return 'Finish the setup in Admin → Extensions → Subdomain Manager.';
    }

    return null;
}
