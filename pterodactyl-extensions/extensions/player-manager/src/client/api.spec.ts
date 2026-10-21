import { http } from '@pterodactyl/sdk';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { describeError, fetchPlayers, runAction } from './api';

// FR-PM2, FR-PM6, FR-PM13, FR-PM18: the endpoints, the shape that is accepted, and the words for every failure.

const UUID = '11111111-2222-4333-8444-555555555555';
const BASE = `/api/client/servers/${UUID}/extensions/player-manager`;

afterEach(() => vi.restoreAllMocks());

describe('fetchPlayers', () => {
    beforeEach(() => {
        vi.spyOn(http, 'get').mockResolvedValue({
            data: { online_count: 1, max_count: 20, players: [{ name: 'Steve', uuid: null, ping: 45, is_op: true }] },
            headers: { 'x-poll-interval': '15000' },
        } as never);
    });

    it('reads the list and the refresh interval from the header', async () => {
        const result = await fetchPlayers(UUID);

        expect(http.get).toHaveBeenCalledWith(`${BASE}/players`);
        expect(result.list).toEqual({ online_count: 1, max_count: 20, players: [{ name: 'Steve', uuid: null, ping: 45, is_op: true }] });
        expect(result.pollMs).toBe(15000);
    });

    it.each([
        ['missing', undefined, 10000],
        ['not a number', 'soon', 10000],
        ['too fast', '100', 5000],
        ['too slow', '999999', 60000],
    ])('holds a %s interval to 5 to 60 seconds, 10 by default (FR-PM13)', async (_label, header, expected) => {
        vi.spyOn(http, 'get').mockResolvedValue({ data: { online_count: 0, max_count: null, players: [] }, headers: header === undefined ? {} : { 'x-poll-interval': header } } as never);

        expect((await fetchPlayers(UUID)).pollMs).toBe(expected);
    });

    it('drops a UUID that is not a UUID, so no avatar is ever built from it (NFR-PM6)', async () => {
        vi.spyOn(http, 'get').mockResolvedValue({
            data: { online_count: 2, max_count: null, players: [{ name: 'A_b', uuid: '../x', ping: null, is_op: null }, { name: 'Cde', uuid: '069A79F444E94726A5BEFCA90E38AAF5', ping: null, is_op: null }] },
            headers: {},
        } as never);

        const { list } = await fetchPlayers(UUID);

        expect(list.players.map((player) => player.uuid)).toEqual([null, '069a79f4-44e9-4726-a5be-fca90e38aaf5']);
    });

    it.each([[null], ['text'], [{}], [{ online_count: 'two', players: [] }], [{ online_count: 1, players: 'x' }]])('rejects an answer of the wrong shape: %j', async (data) => {
        vi.spyOn(http, 'get').mockResolvedValue({ data, headers: {} } as never);

        await expect(fetchPlayers(UUID)).rejects.toThrow(/unexpected shape/);
    });
});

describe('runAction', () => {
    beforeEach(() => {
        vi.spyOn(http, 'post').mockResolvedValue({ data: {} } as never);
    });

    it('posts the action with the reason (AC-PM9)', async () => {
        await runAction(UUID, 'Steve', 'kick', 'griefing');

        expect(http.post).toHaveBeenCalledWith(`${BASE}/players/Steve/kick`, { reason: 'griefing' });
    });

    it('sends no body for op and deop', async () => {
        await runAction(UUID, 'Steve', 'op');

        expect(http.post).toHaveBeenCalledWith(`${BASE}/players/Steve/op`, {});
    });

    it('sends no reason when it is blank', async () => {
        await runAction(UUID, 'Steve', 'ban', '   ');

        expect(http.post).toHaveBeenCalledWith(`${BASE}/players/Steve/ban`, {});
    });

    it('encodes the name, so a strange name cannot add a path (T-PM1)', async () => {
        await runAction(UUID, 'a/../b', 'kick');

        expect(http.post).toHaveBeenCalledWith(`${BASE}/players/a%2F..%2Fb/kick`, {});
    });
});

describe('describeError', () => {
    const failure = (status: number, data: unknown) => ({ isAxiosError: true, response: { status, data } });

    it.each([
        ['rcon_not_configured', /not set up/i],
        ['rcon_connection_failed', /could not be reached/i],
        ['rcon_auth_failed', /password/i],
        ['rcon_timeout', /did not answer/i],
        ['rcon_error', /unexpected answer/i],
    ])('names the problem and the next step for %s (FR-PM18)', (code, body) => {
        const message = describeError(failure(503, { error: code }));

        expect(message.title.length).toBeGreaterThan(0);
        expect(message.body).toMatch(body);
    });

    it('never shows a raw code or any text the server sent', () => {
        const message = describeError(failure(503, { error: 'rcon_error', message: 'SECRET-SERVER-TEXT' }));

        expect(`${message.title} ${message.body}`).not.toMatch(/rcon_|SECRET-SERVER-TEXT/);
    });

    it.each([
        [403, /permission/i],
        [429, /too many/i],
        [422, /name/i],
    ])('explains HTTP %i', (status, body) => {
        expect(describeError(failure(status, {})).body).toMatch(body);
    });

    it('has a plain fallback for anything else', () => {
        expect(describeError(new Error('boom')).title).toBe('Something went wrong');
    });
});
