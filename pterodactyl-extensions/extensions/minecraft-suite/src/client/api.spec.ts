import { http } from '@pterodactyl/sdk';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { describeError, fetchHealth } from './api';

// FR-MS2, FR-MS9, FR-MS14: the endpoint, the shape that is accepted, the interval and the words for every failure.

const UUID = '11111111-2222-4333-8444-555555555555';
const GOOD = { tps: { '1m': 19.98, '5m': 19.99, '15m': 20 }, mspt: 1.2, uptime_seconds: 3600, version: null };

afterEach(() => vi.restoreAllMocks());

const answer = (data: unknown, headers: Record<string, string> = {}) => vi.spyOn(http, 'get').mockResolvedValue({ data, headers } as never);

describe('fetchHealth', () => {
    it('reads the health and the refresh interval from the header', async () => {
        answer(GOOD, { 'x-poll-interval': '15000' });

        const result = await fetchHealth(UUID);

        expect(http.get).toHaveBeenCalledWith(`/api/client/servers/${UUID}/extensions/minecraft-suite/health`);
        expect(result.health).toEqual(GOOD);
        expect(result.pollMs).toBe(15000);
    });

    it.each([
        ['missing', undefined, 10000],
        ['not a number', 'soon', 10000],
        ['too fast', '100', 5000],
        ['too slow', '999999', 60000],
    ])('holds a %s interval to 5 to 60 seconds, 10 by default (FR-MS9)', async (_label, header, expected) => {
        answer(GOOD, header === undefined ? {} : { 'x-poll-interval': header });

        expect((await fetchHealth(UUID)).pollMs).toBe(expected);
    });

    it('keeps null as null for every value that is missing (FR-MS10)', async () => {
        answer({ tps: { '1m': null, '5m': null, '15m': null }, mspt: null, uptime_seconds: null, version: null });

        expect((await fetchHealth(UUID)).health).toEqual({ tps: { '1m': null, '5m': null, '15m': null }, mspt: null, uptime_seconds: null, version: null });
    });

    it('drops a value that cannot be real: negative, not a number, or a text where a number belongs', async () => {
        answer({ tps: { '1m': -3, '5m': 'fast', '15m': 20 }, mspt: -1, uptime_seconds: 'long', version: 12 });

        expect((await fetchHealth(UUID)).health).toEqual({ tps: { '1m': null, '5m': null, '15m': 20 }, mspt: null, uptime_seconds: null, version: null });
    });

    it('keeps a version text, cut to a sensible length', async () => {
        answer({ ...GOOD, version: `1.21.1${'x'.repeat(200)}` });

        expect((await fetchHealth(UUID)).health.version).toBe(`1.21.1${'x'.repeat(58)}`);
    });

    it.each([[null], ['text'], [{}], [{ tps: 'x' }], [{ tps: null }]])('rejects an answer of the wrong shape: %j', async (data) => {
        answer(data);

        await expect(fetchHealth(UUID)).rejects.toThrow(/unexpected shape/);
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
    ])('names the problem and the next step for %s (FR-MS14)', (code, body) => {
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
    ])('explains HTTP %i', (status, body) => {
        expect(describeError(failure(status, {})).body).toMatch(body);
    });

    it('has a plain fallback for anything else', () => {
        expect(describeError(new Error('boom')).title).toBe('Something went wrong');
    });
});
