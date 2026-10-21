import { screen } from '@testing-library/react';
import { http } from '@pterodactyl/sdk';
import { createTestServer } from '@pterodactyl/sdk/testing';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import TpsWidget from './TpsWidget';
import { renderInPanel, SERVER_UUID, usePanelHost } from './test-utils';

// AC-MS17, FR-MS8: the one-minute TPS above the console, only for someone who may read.

usePanelHost();

const server = createTestServer({ uuid: SERVER_UUID, name: 'Survival' });
let body: unknown;

beforeEach(() => {
    body = { tps: { '1m': 19.98, '5m': 19.99, '15m': 20 }, mspt: 1.2, uptime_seconds: 60, version: null };
    vi.spyOn(http, 'get').mockImplementation((async () => ({ data: body, headers: {} })) as never);
});
afterEach(() => vi.restoreAllMocks());

describe('the console widget', () => {
    it('shows the TPS with a word for how it is doing, to someone who may read (AC-MS17)', async () => {
        await renderInPanel(<TpsWidget data={server} />, { permissions: ['ext.minecraft-suite.read'] });

        expect(await screen.findByText('TPS 19.98 · Healthy')).toBeTruthy();
    });

    it('says N/A when there is no reading, not a colour for nothing', async () => {
        body = { tps: { '1m': null, '5m': null, '15m': null }, mspt: null, uptime_seconds: null, version: null };
        await renderInPanel(<TpsWidget data={server} />, { permissions: ['ext.minecraft-suite.read'] });

        expect(await screen.findByText('TPS N/A')).toBeTruthy();
    });

    it('renders nothing, and asks for nothing, without the read permission (T-MS3)', async () => {
        const { container } = await renderInPanel(<TpsWidget data={server} />, { permissions: [] });

        expect(container.textContent).not.toMatch(/TPS/);
        expect(http.get).not.toHaveBeenCalled();
    });

    it('says the reading is unavailable when it cannot be read, instead of a wrong number', async () => {
        vi.spyOn(http, 'get').mockRejectedValue(Object.assign(new Error('503'), { isAxiosError: true, response: { status: 503, data: { error: 'rcon_error' } } }));
        await renderInPanel(<TpsWidget data={server} />, { permissions: ['ext.minecraft-suite.read'] });

        expect(await screen.findByText('TPS unavailable')).toBeTruthy();
    });
});
