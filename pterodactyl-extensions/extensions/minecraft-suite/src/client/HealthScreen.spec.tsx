import { act, screen, within } from '@testing-library/react';
import { http } from '@pterodactyl/sdk';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import HealthScreen from './HealthScreen';
import { renderInPanel, usePanelHost } from './test-utils';

// AC-MS11, AC-MS12, AC-MS16: the numbers with a word beside each colour, N/A for what is missing, and the polling.

usePanelHost();

const READ = ['ext.minecraft-suite.read'];
const HEALTH = { tps: { '1m': 19.98, '5m': 16, '15m': 10 }, mspt: 1.2, uptime_seconds: 5400, version: null };

let gets: number;
let answer: () => Promise<unknown>;
const failure = (status: number, data: unknown) => Object.assign(new Error(`HTTP ${status}`), { isAxiosError: true, response: { status, data } });
const row = (label: string) => screen.getByText(label).closest('div') as HTMLElement;

beforeEach(() => {
    gets = 0;
    answer = async () => ({ data: HEALTH, headers: {} });
    vi.spyOn(http, 'get').mockImplementation((async () => {
        gets++;

        return answer();
    }) as never);
});

afterEach(() => {
    vi.restoreAllMocks();
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
});

describe('the numbers (FR-MS10)', () => {
    it('shows TPS for 1, 5 and 15 minutes, MSPT and uptime (AC-MS11)', async () => {
        await renderInPanel(<HealthScreen />, { permissions: READ });

        expect(await screen.findByText('19.98')).toBeTruthy();
        expect(screen.getByText('16.00')).toBeTruthy();
        expect(screen.getByText('10.00')).toBeTruthy();
        expect(screen.getByText('1.2 ms')).toBeTruthy();
        expect(screen.getByText('1h 30m')).toBeTruthy();
    });

    it('says in words how each TPS is doing: healthy from 19, lagging from 15, struggling below (AC-MS12)', async () => {
        await renderInPanel(<HealthScreen />, { permissions: READ });
        await screen.findByText('19.98');

        expect(within(row('TPS, last minute')).getByText('Healthy')).toBeTruthy();
        expect(within(row('TPS, last 5 minutes')).getByText('Lagging')).toBeTruthy();
        expect(within(row('TPS, last 15 minutes')).getByText('Struggling')).toBeTruthy();
    });

    it('shows N/A for what is not known, and explains a missing TPS reading', async () => {
        answer = async () => ({ data: { tps: { '1m': null, '5m': null, '15m': null }, mspt: null, uptime_seconds: null, version: null }, headers: {} });
        await renderInPanel(<HealthScreen />, { permissions: READ });

        expect(await screen.findAllByText('N/A')).not.toHaveLength(0);
        expect(screen.getByText('No TPS reading')).toBeTruthy();
        expect(screen.getByText(/TPS command/)).toBeTruthy();
    });

    it('does not claim a reading when only some values are missing', async () => {
        answer = async () => ({ data: { ...HEALTH, tps: { '1m': 20, '5m': null, '15m': null } }, headers: {} });
        await renderInPanel(<HealthScreen />, { permissions: READ });
        await screen.findByText('20.00');

        expect(screen.queryByText('No TPS reading')).toBeNull();
    });
});

describe('the states', () => {
    it('says it is loading while it waits for the first answer', async () => {
        answer = () => new Promise(() => {});
        await renderInPanel(<HealthScreen />, { permissions: READ });

        expect(await screen.findByText('Loading health…')).toBeTruthy();
    });

    it('names the problem and the next step when the server cannot be read, without a code (FR-MS14)', async () => {
        answer = async () => {
            throw failure(503, { error: 'rcon_auth_failed' });
        };
        await renderInPanel(<HealthScreen />, { permissions: READ });

        const alert = await screen.findByRole('alert');
        expect(within(alert).getByText('RCON password rejected')).toBeTruthy();
        expect(alert.textContent).not.toMatch(/rcon_/);
    });
});

describe('polling (FR-MS9)', () => {
    const advance = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms));
    const hide = (hidden: boolean) => {
        Object.defineProperty(document, 'visibilityState', { value: hidden ? 'hidden' : 'visible', configurable: true });
        document.dispatchEvent(new Event('visibilitychange'));
    };

    it('asks again every 10 seconds by default (AC-MS11)', async () => {
        vi.useFakeTimers({ shouldAdvanceTime: true });
        await renderInPanel(<HealthScreen />, { permissions: READ });
        await screen.findByText('19.98');
        expect(gets).toBe(1);

        await advance(9_000);
        expect(gets).toBe(1);
        await advance(1_500);
        expect(gets).toBe(2);
    });

    it('follows the interval the server settings ask for', async () => {
        answer = async () => ({ data: HEALTH, headers: { 'x-poll-interval': '5000' } });
        vi.useFakeTimers({ shouldAdvanceTime: true });
        await renderInPanel(<HealthScreen />, { permissions: READ });
        await screen.findByText('19.98');

        await advance(5_500);

        expect(gets).toBe(2);
    });

    it('stops while the tab is hidden and goes on when it is back (AC-MS16, T-MS4)', async () => {
        vi.useFakeTimers({ shouldAdvanceTime: true });
        await renderInPanel(<HealthScreen />, { permissions: READ });
        await screen.findByText('19.98');

        act(() => hide(true));
        await advance(35_000);
        expect(gets).toBe(1);

        act(() => hide(false));
        await advance(11_000);
        expect(gets).toBeGreaterThan(1);
    });
});
