import { screen } from '@testing-library/react';
import { http } from '@pterodactyl/sdk';
import { createTestServer } from '@pterodactyl/sdk/testing';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import PlayerCountWidget from './PlayerCountWidget';
import { renderInPanel, SERVER_UUID, usePanelHost } from './test-utils';

// AC-PM19, FR-PM12: "X/Y players online" above the console, only for someone who may read the list.

usePanelHost();

const server = createTestServer({ uuid: SERVER_UUID, name: 'Survival' });
let body: unknown;

beforeEach(() => {
    body = { online_count: 3, max_count: 20, players: [] };
    vi.spyOn(http, 'get').mockImplementation((async () => ({ data: body, headers: {} })) as never);
});
afterEach(() => vi.restoreAllMocks());

describe('the console widget', () => {
    it('shows how many players are online to someone who may read (AC-PM19)', async () => {
        await renderInPanel(<PlayerCountWidget data={server} />, { permissions: ['ext.player-manager.read'] });

        expect(await screen.findByText('3 / 20 players online')).toBeTruthy();
    });

    it('leaves out the maximum when it is not known', async () => {
        body = { online_count: 3, max_count: null, players: [] };
        await renderInPanel(<PlayerCountWidget data={server} />, { permissions: ['ext.player-manager.read'] });

        expect(await screen.findByText('3 players online')).toBeTruthy();
    });

    it('renders nothing, and asks for nothing, without the read permission (T-PM5)', async () => {
        const { container } = await renderInPanel(<PlayerCountWidget data={server} />, { permissions: ['ext.player-manager.kick'] });

        expect(container.textContent).not.toMatch(/players online/);
        expect(http.get).not.toHaveBeenCalled();
    });

    it('says the count is unavailable when the list cannot be read, instead of a wrong number', async () => {
        vi.spyOn(http, 'get').mockRejectedValue(Object.assign(new Error('503'), { isAxiosError: true, response: { status: 503, data: { error: 'rcon_error' } } }));
        await renderInPanel(<PlayerCountWidget data={server} />, { permissions: ['ext.player-manager.read'] });

        expect(await screen.findByText('Player count unavailable')).toBeTruthy();
    });
});
