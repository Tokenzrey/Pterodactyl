import { fireEvent, screen, waitFor, within } from '@testing-library/react';
import { http } from '@pterodactyl/sdk';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderInPanel, usePanelHost } from '../test-utils';
import Subdomains from './Subdomains';

usePanelHost();

const OVERVIEW = {
    setup: { token: true, domains: 2, target_ip: true, srv_enabled: true },
    counts: { active: 1, pending: 0, failed: 1, deleting: 0, total: 2 },
};
const ROW = (over: Record<string, unknown> = {}) => ({
    id: 1, label: 'kampung', domain: 'mc.example.com', address: 'kampung.mc.example.com', status: 'active', last_error: null, attempts: 0,
    server: { id: 7, name: 'Survival' }, updated_at: '2026-10-20T10:00:00+00:00', ...over,
});

let overview: unknown;
let rows: unknown[];
let calls: { method: string; url: string; params?: Record<string, unknown> }[];

beforeEach(() => {
    overview = OVERVIEW;
    rows = [ROW(), ROW({ id: 2, label: 'rusak', address: 'rusak.mc.example.com', status: 'failed', last_error: 'conflict: Cloudflare already has a record named rusak.mc.example.com', server: null })];
    calls = [];
    vi.spyOn(http, 'get').mockImplementation((async (url: string, config?: { params?: Record<string, unknown> }) => {
        calls.push({ method: 'GET', url, params: config?.params });
        if (url.endsWith('/overview')) {
            return { data: overview };
        }

        return { data: { data: rows, meta: { page: 1, pages: 1, total: rows.length } } };
    }) as never);
    vi.spyOn(http, 'post').mockImplementation((async (url: string) => {
        calls.push({ method: 'POST', url });

        return { data: { problem: null, results: [{ domain: 'mc.example.com', ok: true, message: null }, { domain: 'play.example.org', ok: false, message: '10000: Authentication error' }] } };
    }) as never);
    vi.spyOn(http, 'delete').mockImplementation((async (url: string) => {
        calls.push({ method: 'DELETE', url });

        return { status: 202 };
    }) as never);
});
afterEach(() => vi.restoreAllMocks());

const BASE = '/api/admin/extensions/subdomain-manager';

describe('Subdomains page', () => {
    it('lists every subdomain with its server, status and the error that went with a failure', async () => {
        await renderInPanel(<Subdomains />);
        await screen.findByText('kampung.mc.example.com');

        const table = screen.getByRole('table');
        expect(within(table).getByText('Survival')).toBeTruthy();
        expect(within(table).getByText('Deleted server')).toBeTruthy();
        expect(within(table).getByText('Active')).toBeTruthy();
        expect(within(table).getByText('Failed')).toBeTruthy();
        expect(within(table).getByText(/Cloudflare already has a record named rusak/)).toBeTruthy();
        expect(within(table).getByText('Delete that record at Cloudflare, or choose another label.')).toBeTruthy();
    });

    it('shows what is set up, and the connection test is available when it all is', async () => {
        await renderInPanel(<Subdomains />);

        expect(await screen.findByText('Cloudflare API token saved')).toBeTruthy();
        expect(screen.getByText('2 domains configured')).toBeTruthy();
        expect(screen.getByText('Target IPv4 address set')).toBeTruthy();
        expect((screen.getByRole('button', { name: 'Test Cloudflare connection' }) as HTMLButtonElement).disabled).toBe(false);
    });

    it('says what is missing and blocks the test until the setup is done', async () => {
        overview = { ...OVERVIEW, setup: { token: false, domains: 0, target_ip: true, srv_enabled: true } };

        await renderInPanel(<Subdomains />);

        expect(await screen.findByText('Cloudflare API token saved')).toBeTruthy();
        expect(screen.getByText('At least one domain configured')).toBeTruthy();
        expect(screen.getAllByText('(missing)')).toHaveLength(2);
        expect((screen.getByRole('button', { name: 'Test Cloudflare connection' }) as HTMLButtonElement).disabled).toBe(true);
    });

    it('tests the connection and reports each domain, with Cloudflare\'s own words for a failure', async () => {
        await renderInPanel(<Subdomains />);
        await screen.findByText('Cloudflare API token saved');

        fireEvent.click(screen.getByRole('button', { name: 'Test Cloudflare connection' }));

        const results = await screen.findByRole('list', { name: 'Connection test results' });
        const [first, second] = within(results).getAllByRole('listitem');
        expect(first.textContent).toBe('mc.example.com: connected');
        expect(second.textContent).toBe('play.example.org: could not connect. Cloudflare said: 10000: Authentication error');
        expect(calls.filter((c) => c.method === 'POST').map((c) => c.url)).toEqual([`${BASE}/test`]);
    });

    it('filters by status with counts, and goes back to page 1', async () => {
        await renderInPanel(<Subdomains />);
        await screen.findByText('kampung.mc.example.com');

        fireEvent.click(screen.getByRole('button', { name: 'Failed (1)' }));

        await waitFor(() => expect(calls.some((c) => c.url.endsWith('/records') && c.params?.status === 'failed')).toBe(true));
        expect(screen.getByRole('button', { name: 'Failed (1)' }).getAttribute('aria-pressed')).toBe('true');
        expect(screen.getByRole('button', { name: 'All (2)' }).getAttribute('aria-pressed')).toBe('false');
    });

    it('searches after a short pause and not on every keystroke', async () => {
        await renderInPanel(<Subdomains />);
        await screen.findByText('kampung.mc.example.com');
        const before = calls.filter((c) => c.url.endsWith('/records')).length;

        fireEvent.change(screen.getByRole('searchbox', { name: 'Search addresses' }), { target: { value: 'ka' } });
        fireEvent.change(screen.getByRole('searchbox', { name: 'Search addresses' }), { target: { value: 'kam' } });

        await waitFor(() => expect(calls.filter((c) => c.url.endsWith('/records') && c.params?.q === 'kam')).toHaveLength(1));
        expect(calls.filter((c) => c.url.endsWith('/records') && c.params?.q === 'ka')).toHaveLength(0);
        expect(calls.filter((c) => c.url.endsWith('/records')).length).toBeGreaterThan(before);
    });

    it('retries a stuck subdomain and says so', async () => {
        await renderInPanel(<Subdomains />);
        await screen.findByText('rusak.mc.example.com');

        fireEvent.click(screen.getByRole('button', { name: 'Retry rusak.mc.example.com' }));

        expect(await screen.findByText(/Retry queued/)).toBeTruthy();
        expect(calls.filter((c) => c.method === 'POST' && c.url.endsWith('/retry')).map((c) => c.url)).toEqual([`${BASE}/records/2/retry`]);
        expect(screen.queryByRole('button', { name: 'Retry kampung.mc.example.com' })).toBeNull(); // active rows have nothing to retry
    });

    it('asks before removing, names what is lost, and removes only after confirmation', async () => {
        await renderInPanel(<Subdomains />);
        await screen.findByText('kampung.mc.example.com');

        fireEvent.click(screen.getByRole('button', { name: 'Remove kampung.mc.example.com' }));

        const confirm = screen.getByRole('group', { name: 'Remove kampung.mc.example.com?' });
        expect(confirm.textContent).toContain('Survival keeps running, but players can no longer join with this name.');
        expect(calls.some((c) => c.method === 'DELETE')).toBe(false);

        fireEvent.click(within(confirm).getByRole('button', { name: 'Yes, remove' }));

        await waitFor(() => expect(calls.filter((c) => c.method === 'DELETE').map((c) => c.url)).toEqual([`${BASE}/records/1`]));
        expect(await screen.findByText(/Removal queued/)).toBeTruthy();
    });

    it('can back out of a removal', async () => {
        await renderInPanel(<Subdomains />);
        await screen.findByText('kampung.mc.example.com');

        fireEvent.click(screen.getByRole('button', { name: 'Remove kampung.mc.example.com' }));
        fireEvent.click(screen.getByRole('button', { name: 'Keep it' }));

        expect(screen.queryByRole('group', { name: /^Remove/ })).toBeNull();
        expect(calls.some((c) => c.method === 'DELETE')).toBe(false);
    });

    it('shows an invitation, not an empty table, before any subdomain exists', async () => {
        rows = [];
        overview = { ...OVERVIEW, counts: { active: 0, pending: 0, failed: 0, deleting: 0, total: 0 } };

        await renderInPanel(<Subdomains />);

        expect(await screen.findByText('No subdomains yet')).toBeTruthy();
        expect(screen.getByText(/Open a server in Admin → Servers/)).toBeTruthy();
    });

    it('offers to clear the filters when nothing matches', async () => {
        await renderInPanel(<Subdomains />);
        await screen.findByText('kampung.mc.example.com');
        rows = [];

        fireEvent.click(screen.getByRole('button', { name: 'Failed (1)' }));

        expect(await screen.findByText('Nothing matches')).toBeTruthy();
        expect(screen.getByRole('button', { name: 'Clear filters' })).toBeTruthy();
    });

    it('reports a list that cannot be loaded without exposing the failure', async () => {
        vi.mocked(http.get).mockImplementation((async (url: string) => {
            if (url.endsWith('/overview')) {
                return { data: OVERVIEW };
            }
            throw new Error('SQLSTATE[HY000] secret detail');
        }) as never);

        await renderInPanel(<Subdomains />);

        expect(await screen.findByText(/subdomains could not be loaded/, {}, { timeout: 4000 })).toBeTruthy();
        expect(document.body.textContent).not.toContain('SQLSTATE');
    });

    it('drops rows with an unknown status instead of guessing', async () => {
        rows = [ROW({ status: 'exploded' }), ROW({ id: 3, label: 'ok', address: 'ok.mc.example.com' })];

        await renderInPanel(<Subdomains />);

        expect(await screen.findByText('ok.mc.example.com')).toBeTruthy();
        expect(screen.queryByText('kampung.mc.example.com')).toBeNull();
    });
});
