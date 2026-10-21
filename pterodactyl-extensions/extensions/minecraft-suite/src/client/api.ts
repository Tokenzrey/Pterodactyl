import { http } from '@pterodactyl/sdk';

export interface Health {
    tps: { '1m': number | null; '5m': number | null; '15m': number | null };
    mspt: number | null;
    uptime_seconds: number | null;
    version: string | null;
}

export const DEFAULT_POLL_MS = 10_000;
const MIN_POLL_MS = 5_000;
const MAX_POLL_MS = 60_000;
const MAX_VERSION = 64;

type Json = Record<string, unknown>;
const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value);
/** A number that can be real: finite and not negative. Anything else is "not known". */
const measure = (value: unknown): number | null => (typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null);

/** The refresh interval the server's settings ask for, held to 5 to 60 seconds (FR-MS9). */
function pollInterval(header: unknown): number {
    const value = typeof header === 'string' || typeof header === 'number' ? Number(header) : Number.NaN;

    return Number.isFinite(value) ? Math.min(MAX_POLL_MS, Math.max(MIN_POLL_MS, value)) : DEFAULT_POLL_MS;
}

export async function fetchHealth(uuid: string): Promise<{ health: Health; pollMs: number }> {
    const { data, headers } = await http.get<unknown>(`/api/client/servers/${uuid}/extensions/minecraft-suite/health`);

    if (!isObject(data) || !isObject(data.tps)) {
        throw new Error('The health answer has an unexpected shape.');
    }

    return {
        health: {
            tps: { '1m': measure(data.tps['1m']), '5m': measure(data.tps['5m']), '15m': measure(data.tps['15m']) },
            mspt: measure(data.mspt),
            uptime_seconds: Number.isInteger(data.uptime_seconds) ? measure(data.uptime_seconds) : null,
            version: typeof data.version === 'string' ? data.version.slice(0, MAX_VERSION) : null,
        },
        pollMs: pollInterval((headers as Record<string, unknown> | undefined)?.['x-poll-interval']),
    };
}

export interface Message {
    title: string;
    body: string;
}

/** What went wrong, in this bundle's own words. Nothing the server sent is ever shown, and no code. */
const RCON: Record<string, Message> = {
    rcon_not_configured: { title: 'RCON is not set up', body: 'RCON is not set up for this server. Ask an administrator to enter its host, port and password.' },
    rcon_connection_failed: { title: 'Cannot reach the server', body: 'The server could not be reached over RCON. Check that it is running and that RCON is turned on in server.properties.' },
    rcon_auth_failed: { title: 'RCON password rejected', body: 'The server refused the RCON password. Ask an administrator to compare it with rcon.password in server.properties.' },
    rcon_timeout: { title: 'The server is not answering', body: 'The server did not answer in time. Try again in a moment.' },
    rcon_error: { title: 'Unexpected answer from the server', body: 'The server gave an unexpected answer. Try again; if it keeps happening, tell an administrator.' },
};

const BY_STATUS: Record<number, Message> = {
    403: { title: 'Not allowed', body: 'You do not have permission to see this server’s health.' },
    429: { title: 'Too many requests', body: 'Too many requests. Wait a minute and try again.' },
};

export function describeError(error: unknown): Message {
    const response = isObject(error) && isObject(error.response) ? error.response : null;
    const status = typeof response?.status === 'number' ? response.status : 0;
    const code = isObject(response?.data) && typeof response.data.error === 'string' ? response.data.error : '';

    return RCON[code] ?? BY_STATUS[status] ?? { title: 'Something went wrong', body: 'Try again in a moment. If it keeps happening, tell an administrator.' };
}
