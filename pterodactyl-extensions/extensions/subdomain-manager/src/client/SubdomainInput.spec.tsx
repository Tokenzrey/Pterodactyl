import { act, cleanup, fireEvent, screen, waitFor } from '@testing-library/react';
import { http, type FormExtensionProps } from '@pterodactyl/sdk';
import { useRef, useState } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Availability, SubdomainConfig } from './api';
import { SubdomainInput, type SubdomainValues } from './SubdomainInput';
import { renderInPanel, usePanelHost } from './test-utils';

// FR-S11, AC-S17: label, domain, preview, availability after 500 ms (cancelled when the input changes),
// status and errors. The panel host is real; the two backend calls are replaced.

usePanelHost();

const CONFIG: SubdomainConfig = { domains: ['mc.example.com', 'play.example.org'], srv_enabled: true, reserved_labels: ['www', 'mail'] };
const FREE: Availability = { available: true, reason: null, checked_cloudflare: true };

type Props = FormExtensionProps<SubdomainValues, 'admin.server'>;
let latest: SubdomainValues;

function Harness({ initial = {}, errors = {}, serverId }: { initial?: Partial<SubdomainValues>; errors?: Partial<Record<keyof SubdomainValues, string>>; serverId?: number }) {
    const [values, setValues] = useState<SubdomainValues>({ label: '', domain: '', status: null, fqdn: null, error: null, ...initial });
    latest = values;
    const stable = useRef(values);
    stable.current = values;

    const field = ((name: keyof SubdomainValues & string) => ({
        id: `sdm-${name}`,
        name: `extensions.subdomain-manager.${name}`,
        value: values[name],
        setValue: (value: string) => setValues((previous) => ({ ...previous, [name]: value })),
        error: errors[name],
    })) as unknown as Props['field'];
    const resource = serverId === undefined ? undefined : ({ object: 'server', attributes: { id: serverId } } as unknown as Props['resource']);

    return <SubdomainInput form="admin.server" mode={serverId === undefined ? 'create' : 'edit'} resource={resource} values={values} field={field} />;
}

let calls: { url: string; params?: Record<string, unknown>; signal?: AbortSignal }[];
let answer: (params: Record<string, unknown>, signal: AbortSignal) => Promise<{ data: unknown }>;

beforeEach(() => {
    calls = [];
    answer = async () => ({ data: FREE });
    vi.spyOn(http, 'get').mockImplementation((async (url: string, config?: { params?: Record<string, unknown>; signal?: AbortSignal }) => {
        calls.push({ url, params: config?.params, signal: config?.signal });

        return url.endsWith('/config') ? { data: CONFIG } : answer(config?.params ?? {}, config?.signal as AbortSignal);
    }) as never);
});

afterEach(() => {
    vi.restoreAllMocks();
});

const availabilityCalls = () => calls.filter((call) => call.url.endsWith('/availability'));
const labelInput = () => screen.getByLabelText('Label') as HTMLInputElement;
const domainInput = () => screen.getByLabelText('Domain') as HTMLInputElement;
const type = (value: string) => fireEvent.change(labelInput(), { target: { value } });
const advance = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms));
/** The panel's combobox opens its list from the "Open popup" trigger; picking an option is a click on it. */
const openDomains = () => fireEvent.click(screen.getByRole('button', { name: 'Open popup' }));
const pickDomain = (name: string) => {
    openDomains();
    fireEvent.click(screen.getByRole('option', { name }));
};

/** Renders, waits for the configuration with real timers, then switches to fake ones for the debounce. */
async function ready(ui = <Harness />) {
    await renderInPanel(ui);
    await waitFor(() => expect(domainInput().disabled).toBe(false));
    vi.useFakeTimers();
}

describe('the form (FR-S11)', () => {
    it('offers the configured domains and lets the label be typed', async () => {
        await ready();

        openDomains();

        expect(screen.getAllByRole('option').map((option) => option.textContent)).toEqual(['mc.example.com', 'play.example.org']);
        expect(screen.getByText('Type a label to see the address players will use.')).toBeTruthy();
    });

    it('picks the first configured domain as soon as a label is typed, and previews the address', async () => {
        await ready();

        type('kampung');
        await advance(0);

        expect(domainInput().value).toBe('mc.example.com');
        expect(screen.getByText('kampung.mc.example.com')).toBeTruthy();
        expect(latest).toMatchObject({ label: 'kampung', domain: 'mc.example.com' });
    });

    it('follows the domain when another is chosen', async () => {
        await ready(<Harness initial={{ label: 'kampung', domain: 'mc.example.com' }} />);

        pickDomain('play.example.org');
        await advance(0);

        expect(screen.getByText('kampung.play.example.org')).toBeTruthy();
        expect(latest.domain).toBe('play.example.org');
    });

    it('turns upper case into lower case as it is typed', async () => {
        await ready();

        type('Kampung');
        await advance(0);

        expect(labelInput().value).toBe('kampung');
    });

    it('AC-S17 clearing the label sends an empty string and says the subdomain will be removed', async () => {
        await ready(<Harness initial={{ label: 'kampung', domain: 'mc.example.com', status: 'active', fqdn: 'kampung.mc.example.com' }} serverId={7} />);

        type('');
        await advance(600);

        expect(latest.label).toBe('');
        expect(screen.getByText(/removes/).textContent).toContain('kampung.mc.example.com');
        expect(availabilityCalls()).toHaveLength(0);
    });
});

describe('availability (AC-S17)', () => {
    it('asks once, 500 ms after the last keystroke, for the name as it stands', async () => {
        await ready(<Harness serverId={42} />);

        type('k');
        await advance(200);
        type('ka');
        await advance(200);
        type('kampung');
        await advance(499);
        expect(availabilityCalls()).toHaveLength(0);

        await advance(1);

        expect(availabilityCalls()).toHaveLength(1);
        expect(availabilityCalls()[0].params).toEqual({ domain: 'mc.example.com', label: 'kampung', server: 42 });
    });

    it('shows the answer', async () => {
        await ready();

        type('kampung');
        await advance(500);
        await advance(0);

        expect(screen.getByRole('status').textContent).toContain('Available.');
    });

    it('says when Cloudflare could not be asked', async () => {
        answer = async () => ({ data: { ...FREE, checked_cloudflare: false } });
        await ready();

        type('kampung');
        await advance(500);
        await advance(0);

        expect(screen.getByRole('status').textContent).toContain('not checked at Cloudflare');
    });

    it.each([
        ['taken', 'Another server already uses this name.'],
        ['exists_at_cloudflare', 'A DNS record with this name already exists at Cloudflare and was not made by this panel. Delete it there, or choose another label.'],
        ['unconfigured', 'Choose one of the configured domains.'],
    ] as const)('explains %s in the bundle\'s own words', async (reason, text) => {
        answer = async () => ({ data: { available: false, reason, checked_cloudflare: false } });
        await ready();

        type('kampung');
        await advance(500);
        await advance(0);

        expect(screen.getByRole('status').textContent).toBe(text);
    });

    it('does not repeat text the server sent: an unknown reason shows nothing', async () => {
        answer = async () => ({ data: { available: false, reason: '<img src=x onerror=alert(1)>', checked_cloudflare: true } });
        await ready();

        type('kampung');
        await advance(500);
        await advance(0);

        expect(screen.getByRole('status').textContent).toBe('');
        expect(document.querySelector('img')).toBeNull();
    });

    it('answers invalid and reserved names itself, without asking the server', async () => {
        await ready();

        type('www');
        await advance(1000);
        expect(screen.getByRole('status').textContent).toBe('This name is reserved.');

        type('-bad');
        await advance(1000);
        expect(screen.getByRole('status').textContent).toContain('lower-case letters, digits or hyphens');
        expect(availabilityCalls()).toHaveLength(0);
    });

    it('cancels a request still on its way when the input changes, and ignores its late answer', async () => {
        const pending: ((value: { data: unknown }) => void)[] = [];
        answer = (_params, signal) => new Promise((resolve, reject) => {
            pending.push(resolve);
            signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
        });
        await ready();

        type('first');
        await advance(500);
        const firstSignal = availabilityCalls()[0].signal as AbortSignal;
        expect(firstSignal.aborted).toBe(false);

        type('second');
        expect(firstSignal.aborted).toBe(true);
        await advance(500);
        expect(availabilityCalls()).toHaveLength(2);

        pending[0]({ data: { available: false, reason: 'taken', checked_cloudflare: true } }); // the old answer, too late
        pending[1]({ data: FREE });
        await advance(0);

        expect(screen.getByRole('status').textContent).toContain('Available.');
    });

    it('cancels the request when the form goes away', async () => {
        answer = (_params, signal) => new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError'))));
        await ready();

        type('kampung');
        await advance(500);
        const signal = availabilityCalls()[0].signal as AbortSignal;
        expect(signal.aborted).toBe(false);

        cleanup();

        expect(signal.aborted).toBe(true);
    });

    it('stops waiting when the form goes away before the pause is over', async () => {
        await ready();

        type('kampung');
        await advance(100);
        cleanup();
        await advance(1000);

        expect(availabilityCalls()).toHaveLength(0);
    });

    it('says so when the check itself fails', async () => {
        answer = async () => {
            throw new Error('network');
        };
        await ready();

        type('kampung');
        await advance(500);
        await advance(0);

        expect(screen.getByRole('status').textContent).toBe('Availability could not be checked.');
    });
});

describe('status and errors', () => {
    it.each([
        ['active', 'Active'],
        ['pending', 'Waiting for Cloudflare'],
        ['failed', 'Failed'],
        ['deleting', 'Being removed'],
    ])('shows a saved row that is %s', async (status, text) => {
        await ready(<Harness initial={{ label: 'kampung', domain: 'mc.example.com', status, fqdn: 'kampung.mc.example.com', error: status === 'failed' ? 'conflict: a record exists' : null }} serverId={3} />);

        expect(screen.getByText(text)).toBeTruthy();
        if (status === 'failed') {
            expect(document.body.textContent).toContain('conflict: a record exists');
        }
    });

    it('shows the panel validation messages next to the fields', async () => {
        await ready(<Harness initial={{ label: 'www', domain: 'mc.example.com' }} errors={{ label: 'This label is reserved and cannot be used.', domain: 'That domain is not one of the configured domains.' }} />);

        const alerts = screen.getAllByRole('alert').map((alert) => alert.textContent ?? '');
        expect(alerts).toHaveLength(2);
        expect(alerts[0]).toContain('The label was not saved');
        expect(alerts[0]).toContain('This label is reserved and cannot be used.');
        expect(alerts[1]).toContain('The domain was not saved');
        expect(alerts[1]).toContain('That domain is not one of the configured domains.');
    });

    it('asks the administrator to configure a domain when there is none, and locks the inputs', async () => {
        vi.mocked(http.get).mockImplementation((async (url: string) => (url.endsWith('/config') ? { data: { ...CONFIG, domains: [] } } : { data: FREE })) as never);
        await renderInPanel(<Harness />);
        await screen.findByText(/No domain is configured yet/);

        expect(labelInput().disabled).toBe(true);
        expect(domainInput().disabled).toBe(true);
    });

    it('reports a configuration that could not be loaded', async () => {
        vi.mocked(http.get).mockImplementation((async () => {
            throw new Error('boom');
        }) as never);
        await renderInPanel(<Harness />);

        expect(await screen.findByText(/could not be loaded/, {}, { timeout: 3000 })).toBeTruthy();
    });

    it('refuses a configuration of the wrong shape', async () => {
        vi.mocked(http.get).mockImplementation((async () => ({ data: { domains: 'mc.example.com' } })) as never);
        await renderInPanel(<Harness />);

        expect(await screen.findByText(/could not be loaded/, {}, { timeout: 3000 })).toBeTruthy();
    });
});

describe('the address block', () => {
    it('explains that no port is needed when SRV is on', async () => {
        await ready(<Harness initial={{ label: 'kampung', domain: 'mc.example.com' }} />);

        expect(screen.getByText(/No port needed/)).toBeTruthy();
    });

    it('explains that the port must be added when SRV is off', async () => {
        vi.mocked(http.get).mockImplementation((async (url: string) => (url.endsWith('/config') ? { data: { ...CONFIG, srv_enabled: false } } : { data: FREE })) as never);

        await ready(<Harness initial={{ label: 'kampung', domain: 'mc.example.com' }} />);

        expect(screen.getByText(/server port must be added/)).toBeTruthy();
    });

    it('offers to copy the address', async () => {
        await ready(<Harness initial={{ label: 'kampung', domain: 'mc.example.com' }} />);

        expect(screen.getByRole('button', { name: 'Copy address' })).toBeTruthy();
    });

    it('clears a saved label with one honest button, and says that saving is what removes the name', async () => {
        await ready(<Harness initial={{ label: 'kampung', domain: 'mc.example.com', status: 'active', fqdn: 'kampung.mc.example.com' }} serverId={5} />);

        fireEvent.click(screen.getByRole('button', { name: 'Clear label' }));
        await advance(0);

        expect(latest.label).toBe('');
        expect(screen.queryByRole('button', { name: 'Clear label' })).toBeNull();
        expect(screen.getByText(/removes/).textContent).toContain('kampung.mc.example.com');
    });

    it('does not offer to clear a name that was never saved', async () => {
        await ready(<Harness initial={{ label: 'kampung', domain: 'mc.example.com' }} />);

        expect(screen.queryByRole('button', { name: 'Clear label' })).toBeNull();
    });

    it.each([
        ['conflict: Cloudflare already has a record named x', 'Delete that record at Cloudflare, or choose another label.'],
        ['config: the Cloudflare token is not set', 'Finish the setup in Admin → Extensions → Subdomain Manager.'],
    ])('tells what to do about %s', async (error, advice) => {
        await ready(<Harness initial={{ label: 'kampung', domain: 'mc.example.com', status: 'failed', fqdn: 'kampung.mc.example.com', error }} serverId={3} />);

        expect(document.body.textContent).toContain(`Last error: ${error}`);
        expect(screen.getByText(advice)).toBeTruthy();
    });

    it('gives an error without known advice no invented advice', async () => {
        await ready(<Harness initial={{ label: 'kampung', domain: 'mc.example.com', status: 'failed', fqdn: 'kampung.mc.example.com', error: '10000: Authentication error' }} serverId={3} />);

        expect(document.body.textContent).toContain('10000: Authentication error');
        expect(screen.queryByText(/Delete that record|Finish the setup/)).toBeNull();
    });
});
