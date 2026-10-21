import { http } from '@pterodactyl/sdk';
import { normalizeUuid } from './crafatar';

export interface Player {
    name: string;
    uuid: string | null;
    ping: number | null;
    is_op: boolean | null;
}

export interface PlayerList {
    online_count: number;
    max_count: number | null;
    players: Player[];
}

export type PlayerAction = 'kick' | 'ban' | 'op' | 'deop';

export const DEFAULT_POLL_MS = 10_000;
const MIN_POLL_MS = 5_000;
const MAX_POLL_MS = 60_000;

type Json = Record<string, unknown>;
const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value);
const base = (uuid: string) => `/api/client/servers/${uuid}/extensions/player-manager`;

function player(value: unknown): Player {
    const raw = isObject(value) ? value : {};

    return {
        name: typeof raw.name === 'string' ? raw.name : '',
        // Checked again here: an avatar URL is only ever built from a UUID this bundle has validated (NFR-PM6).
        uuid: normalizeUuid(raw.uuid),
        ping: typeof raw.ping === 'number' && Number.isInteger(raw.ping) ? raw.ping : null,
        is_op: typeof raw.is_op === 'boolean' ? raw.is_op : null,
    };
}

/** The refresh interval the server's settings ask for, held to 5 to 60 seconds (FR-PM13). */
function pollInterval(header: unknown): number {
    const value = typeof header === 'string' || typeof header === 'number' ? Number(header) : Number.NaN;

    return Number.isFinite(value) ? Math.min(MAX_POLL_MS, Math.max(MIN_POLL_MS, value)) : DEFAULT_POLL_MS;
}

export async function fetchPlayers(uuid: string): Promise<{ list: PlayerList; pollMs: number }> {
    const { data, headers } = await http.get<unknown>(`${base(uuid)}/players`);

    if (!isObject(data) || !Number.isInteger(data.online_count) || (data.online_count as number) < 0 || !Array.isArray(data.players)) {
        throw new Error('The player list has an unexpected shape.');
    }

    return {
        list: {
            online_count: data.online_count as number,
            max_count: typeof data.max_count === 'number' && Number.isInteger(data.max_count) ? data.max_count : null,
            players: data.players.map(player),
        },
        pollMs: pollInterval((headers as Record<string, unknown> | undefined)?.['x-poll-interval']),
    };
}

/** Kick, ban, op or deop one player. The reason only matters to kick and ban; a blank one is not sent. */
export async function runAction(uuid: string, name: string, action: PlayerAction, reason?: string): Promise<void> {
    const trimmed = reason?.trim();

    await http.post(`${base(uuid)}/players/${encodeURIComponent(name)}/${action}`, trimmed ? { reason: trimmed } : {});
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
    403: { title: 'Not allowed', body: 'You do not have permission to do that on this server.' },
    422: { title: 'That name cannot be used', body: 'That player name is not a valid Minecraft name, or the reason is too long.' },
    429: { title: 'Too many requests', body: 'Too many requests. Wait a minute and try again.' },
};

export function describeError(error: unknown): Message {
    const response = isObject(error) && isObject(error.response) ? error.response : null;
    const status = typeof response?.status === 'number' ? response.status : 0;
    const code = isObject(response?.data) && typeof response.data.error === 'string' ? response.data.error : '';

    return RCON[code] ?? BY_STATUS[status] ?? { title: 'Something went wrong', body: 'Try again in a moment. If it keeps happening, tell an administrator.' };
}
