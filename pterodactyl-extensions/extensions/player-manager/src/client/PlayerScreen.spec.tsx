import { act, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { http } from '@pterodactyl/sdk';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import PlayerScreen from './PlayerScreen';
import { renderInPanel, SERVER_UUID, usePanelHost } from './test-utils';

// AC-PM15 to AC-PM18: the list, the gated buttons, the confirm-then-act flow, the states, and the polling.

usePanelHost();

const READ = 'ext.player-manager.read';
const ALL = [READ, 'ext.player-manager.kick', 'ext.player-manager.ban', 'ext.player-manager.op', 'ext.player-manager.deop'];
const STEVE = '069a79f4-44e9-4726-a5be-fca90e38aaf5';
const BASE = `/api/client/servers/${SERVER_UUID}/extensions/player-manager`;

const LIST = {
    online_count: 3,
    max_count: 20,
    players: [
        { name: 'Steve', uuid: STEVE, ping: 45, is_op: true },
        { name: 'Alex', uuid: null, ping: 78, is_op: false },
        { name: 'Notch', uuid: null, ping: null, is_op: null },
    ],
};

let gets: number;
let answer: () => Promise<unknown>;

const failure = (status: number, data: unknown) => Object.assign(new Error(`HTTP ${status}`), { isAxiosError: true, response: { status, data } });

beforeEach(() => {
    gets = 0;
    answer = async () => ({ data: LIST, headers: {} });
    vi.spyOn(http, 'get').mockImplementation((async () => {
        gets++;

        return answer();
    }) as never);
    vi.spyOn(http, 'post').mockResolvedValue({ data: {} } as never);
});

afterEach(() => {
    vi.restoreAllMocks();
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
});

describe('the list (FR-PM14)', () => {
    it('shows the count, every player, their ping and who is an operator (AC-PM15)', async () => {
        await renderInPanel(<PlayerScreen />, { permissions: [READ] });

        expect(await screen.findByText('3 / 20 players online')).toBeTruthy();
        expect(screen.getByText('Steve')).toBeTruthy();
        expect(screen.getByText('Alex')).toBeTruthy();
        expect(screen.getByText('45 ms')).toBeTruthy();
        expect(screen.getAllByText('OP')).toHaveLength(1);
    });

    it('draws a Crafatar avatar for a valid UUID, lazily (AC-PM16)', async () => {
        await renderInPanel(<PlayerScreen />, { permissions: [READ] });
        await screen.findByText('Steve');

        const avatar = screen.getByAltText('Steve') as HTMLImageElement;
        expect(avatar.src).toBe(`https://crafatar.com/avatars/${STEVE}?size=64`);
        expect(avatar.getAttribute('loading')).toBe('lazy');
    });

    it('draws no image for a player without a UUID: a text placeholder instead (AC-PM17)', async () => {
        await renderInPanel(<PlayerScreen />, { permissions: [READ] });
        await screen.findByText('Alex');

        expect(screen.queryByAltText('Alex')).toBeNull();
        expect(screen.getAllByRole('img')).toHaveLength(1);
    });

    it('says it is loading while it waits for the first answer', async () => {
        answer = () => new Promise(() => {});
        await renderInPanel(<PlayerScreen />, { permissions: [READ] });
        expect(await screen.findByText('Loading players…')).toBeTruthy();
    });

    it('says so when nobody is online', async () => {
        answer = async () => ({ data: { online_count: 0, max_count: 20, players: [] }, headers: {} });
        await renderInPanel(<PlayerScreen />, { permissions: [READ] });

        expect(await screen.findByText('Nobody is online')).toBeTruthy();
    });

    it('shows a player with no readable name as unknown, with no way to act on it (EC-PM3)', async () => {
        answer = async () => ({ data: { online_count: 1, max_count: null, players: [{ name: '', uuid: null, ping: null, is_op: null }] }, headers: {} });
        await renderInPanel(<PlayerScreen />, { permissions: ALL });

        expect(await screen.findByText('Unknown player')).toBeTruthy();
        expect(screen.queryByRole('button', { name: /^Kick/ })).toBeNull();
        expect(screen.getByText('1 player online')).toBeTruthy();
    });
});

describe('the buttons follow the permissions (FR-PM14, T-PM4)', () => {
    it('shows none to someone who may only read', async () => {
        await renderInPanel(<PlayerScreen />, { permissions: [READ] });
        await screen.findByText('Steve');

        expect(screen.queryAllByRole('button')).toHaveLength(0);
    });

    it('shows only Kick to someone with the kick permission (AC-PM15)', async () => {
        await renderInPanel(<PlayerScreen />, { permissions: [READ, 'ext.player-manager.kick'] });
        await screen.findByText('Steve');

        expect(screen.getByRole('button', { name: 'Kick Steve' })).toBeTruthy();
        expect(screen.queryByRole('button', { name: 'Ban Steve' })).toBeNull();
        expect(screen.queryByRole('button', { name: /OP/ })).toBeNull();
    });

    it('offers Remove OP to an operator, Make OP to anyone else, and both where it is not known', async () => {
        await renderInPanel(<PlayerScreen />, { permissions: ALL });
        await screen.findByText('Steve');

        expect(screen.getByRole('button', { name: 'Remove OP from Steve' })).toBeTruthy();
        expect(screen.queryByRole('button', { name: 'Make Steve an OP' })).toBeNull();
        expect(screen.getByRole('button', { name: 'Make Alex an OP' })).toBeTruthy();
        expect(screen.queryByRole('button', { name: 'Remove OP from Alex' })).toBeNull();
        expect(screen.getByRole('button', { name: 'Make Notch an OP' })).toBeTruthy();
        expect(screen.getByRole('button', { name: 'Remove OP from Notch' })).toBeTruthy();
    });

    it('shows every button to the owner', async () => {
        await renderInPanel(<PlayerScreen />, { owner: true });
        await screen.findByText('Steve');

        expect(screen.getByRole('button', { name: 'Ban Steve' })).toBeTruthy();
    });
});

describe('an action asks first, then runs (FR-PM6)', () => {
    it('kicks with the reason after a confirmation, then says so and reloads the list (AC-PM9)', async () => {
        await renderInPanel(<PlayerScreen />, { permissions: ALL });
        await screen.findByText('Steve');

        fireEvent.click(screen.getByRole('button', { name: 'Kick Steve' }));
        const confirm = screen.getByRole('group', { name: 'Kick Steve?' });
        expect(http.post).not.toHaveBeenCalled();

        fireEvent.change(within(confirm).getByLabelText('Reason (optional)'), { target: { value: 'griefing' } });
        fireEvent.click(within(confirm).getByRole('button', { name: 'Yes, kick Steve' }));

        await waitFor(() => expect(http.post).toHaveBeenCalledWith(`${BASE}/players/Steve/kick`, { reason: 'griefing' }));
        expect(await screen.findByText('Kick command sent for Steve.')).toBeTruthy();
        await waitFor(() => expect(gets).toBe(2));
        expect(screen.queryByRole('group', { name: 'Kick Steve?' })).toBeNull();
    });

    it('does nothing when cancelled', async () => {
        await renderInPanel(<PlayerScreen />, { permissions: ALL });
        await screen.findByText('Steve');

        fireEvent.click(screen.getByRole('button', { name: 'Ban Steve' }));
        fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

        expect(screen.queryByRole('group', { name: 'Ban Steve?' })).toBeNull();
        expect(http.post).not.toHaveBeenCalled();
    });

    it('explains what each action does before it is confirmed', async () => {
        await renderInPanel(<PlayerScreen />, { permissions: ALL });
        await screen.findByText('Steve');

        fireEvent.click(screen.getByRole('button', { name: 'Make Alex an OP' }));

        expect(within(screen.getByRole('group', { name: 'Make Alex an OP?' })).getByText(/every command/i)).toBeTruthy();
    });

    it('asks for no reason when making someone an operator', async () => {
        await renderInPanel(<PlayerScreen />, { permissions: ALL });
        await screen.findByText('Steve');

        fireEvent.click(screen.getByRole('button', { name: 'Make Alex an OP' }));
        const confirm = screen.getByRole('group', { name: 'Make Alex an OP?' });
        expect(within(confirm).queryByLabelText('Reason (optional)')).toBeNull();

        fireEvent.click(within(confirm).getByRole('button', { name: 'Yes, make Alex an OP' }));
        await waitFor(() => expect(http.post).toHaveBeenCalledWith(`${BASE}/players/Alex/op`, {}));
    });

    it('says what failed and what to do when the action fails, and keeps the list', async () => {
        vi.spyOn(http, 'post').mockRejectedValue(failure(503, { error: 'rcon_auth_failed' }));
        await renderInPanel(<PlayerScreen />, { permissions: ALL });
        await screen.findByText('Steve');

        fireEvent.click(screen.getByRole('button', { name: 'Kick Steve' }));
        fireEvent.click(screen.getByRole('button', { name: 'Yes, kick Steve' }));

        const alert = await screen.findByRole('alert');
        expect(within(alert).getByText('RCON password rejected')).toBeTruthy();
        expect(screen.getByText('Steve')).toBeTruthy();
    });
});

describe('when the list cannot be loaded (FR-PM18)', () => {
    it('names the problem and the next step, without a code', async () => {
        answer = async () => {
            throw failure(503, { error: 'rcon_not_configured' });
        };
        await renderInPanel(<PlayerScreen />, { permissions: [READ] });

        const alert = await screen.findByRole('alert');
        expect(within(alert).getByText('RCON is not set up')).toBeTruthy();
        expect(alert.textContent).not.toMatch(/rcon_/);
    });
});

describe('polling (FR-PM13)', () => {
    const advance = (ms: number) => act(() => vi.advanceTimersByTimeAsync(ms));
    const hide = (hidden: boolean) => {
        Object.defineProperty(document, 'visibilityState', { value: hidden ? 'hidden' : 'visible', configurable: true });
        document.dispatchEvent(new Event('visibilitychange'));
    };

    it('asks again every 10 seconds by default (AC-PM15)', async () => {
        vi.useFakeTimers({ shouldAdvanceTime: true });
        await renderInPanel(<PlayerScreen />, { permissions: [READ] });
        await screen.findByText('Steve');
        expect(gets).toBe(1);

        await advance(9_000);
        expect(gets).toBe(1);
        await advance(1_500);
        expect(gets).toBe(2);
    });

    it('follows the interval the server settings ask for', async () => {
        answer = async () => ({ data: LIST, headers: { 'x-poll-interval': '5000' } });
        vi.useFakeTimers({ shouldAdvanceTime: true });
        await renderInPanel(<PlayerScreen />, { permissions: [READ] });
        await screen.findByText('Steve');

        await advance(5_500);

        expect(gets).toBe(2);
    });

    it('stops while the tab is hidden and goes on when it is back (AC-PM18, T-PM6)', async () => {
        vi.useFakeTimers({ shouldAdvanceTime: true });
        await renderInPanel(<PlayerScreen />, { permissions: [READ] });
        await screen.findByText('Steve');

        act(() => hide(true));
        await advance(35_000);
        expect(gets).toBe(1);

        act(() => hide(false));
        await advance(11_000);
        expect(gets).toBeGreaterThan(1);
    });
});
