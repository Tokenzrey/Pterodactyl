import { http } from '@pterodactyl/sdk';
import { isStatus, REASON_TEXT, type Reason, type Status } from './labels';

const BASE = '/api/admin/extensions/subdomain-manager';

type Json = Record<string, unknown>;
const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value);
const isStringList = (value: unknown): value is string[] => Array.isArray(value) && value.every((item) => typeof item === 'string');
const unexpected = (what: string) => new Error(`The ${what} has an unexpected shape.`);

/** `routed` sends every name to the one port of the router; `per_port` gives each server its own (the default). */
export type Mode = 'routed' | 'per_port';

export interface SubdomainConfig {
    domains: string[];
    srv_enabled: boolean;
    mode: Mode;
    reserved_labels: string[];
}

export async function fetchConfig(): Promise<SubdomainConfig> {
    const { data } = await http.get<unknown>(`${BASE}/config`);

    if (!isObject(data) || !isStringList(data.domains) || !isStringList(data.reserved_labels)) {
        throw unexpected('subdomain configuration');
    }

    return { domains: data.domains, srv_enabled: data.srv_enabled !== false, mode: data.mode === 'routed' ? 'routed' : 'per_port', reserved_labels: data.reserved_labels };
}

/** Whether games sync routes a server's name, and if not, why (FR-R5). */
export interface Routing {
    state: 'ready' | 'invalid';
    reason: string | null;
}

/** Reads the routing answer of a list row or a form; null when the mode has no router (per-port) or there is no server. */
export function parseRouting(value: unknown): Routing | null {
    if (!isObject(value) || (value.state !== 'ready' && value.state !== 'invalid')) {
        return null;
    }

    return { state: value.state, reason: typeof value.reason === 'string' ? value.reason : null };
}

export interface Availability {
    available: boolean;
    reason: Reason | null;
    checked_cloudflare: boolean;
}

/** Asks whether a name is free. `signal` cancels the request when the input changes before it answers. */
export async function checkAvailability(params: { domain: string; label: string; server?: number }, signal: AbortSignal): Promise<Availability> {
    const { data } = await http.get<unknown>(`${BASE}/availability`, { params, signal });

    if (!isObject(data) || typeof data.available !== 'boolean') {
        throw unexpected('availability answer');
    }
    // A reason this version does not know is treated as no reason: the text shown always comes from this bundle.
    const reason = typeof data.reason === 'string' && Object.hasOwn(REASON_TEXT, data.reason) ? (data.reason as Reason) : null;

    return { available: data.available, reason, checked_cloudflare: data.checked_cloudflare === true };
}

export interface Overview {
    setup: { token: boolean; domains: number; target_ip: boolean; srv_enabled: boolean };
    counts: Record<Status | 'total', number>;
}

export async function fetchOverview(): Promise<Overview> {
    const { data } = await http.get<unknown>(`${BASE}/overview`);
    if (!isObject(data) || !isObject(data.setup) || !isObject(data.counts)) {
        throw unexpected('overview');
    }
    const { setup, counts } = data;
    const count = (key: string) => (typeof counts[key] === 'number' ? (counts[key] as number) : 0);

    return {
        setup: { token: setup.token === true, domains: typeof setup.domains === 'number' ? setup.domains : 0, target_ip: setup.target_ip === true, srv_enabled: setup.srv_enabled !== false },
        counts: { active: count('active'), pending: count('pending'), failed: count('failed'), deleting: count('deleting'), total: count('total') },
    };
}

export interface ConnectionResult {
    problem: 'token' | 'domains' | null;
    results: { domain: string; ok: boolean; message: string | null }[];
}

/** Reads one record from every configured zone at Cloudflare. */
export async function testConnection(): Promise<ConnectionResult> {
    const { data } = await http.post<unknown>(`${BASE}/test`);
    if (!isObject(data) || !Array.isArray(data.results)) {
        throw unexpected('connection test');
    }

    return {
        problem: data.problem === 'token' || data.problem === 'domains' ? data.problem : null,
        results: data.results.filter(isObject).map((item) => ({ domain: String(item.domain ?? ''), ok: item.ok === true, message: typeof item.message === 'string' ? item.message : null })),
    };
}

export interface RecordRow {
    id: number;
    label: string;
    domain: string;
    address: string;
    status: Status;
    last_error: string | null;
    attempts: number;
    server: { id: number; name: string } | null;
    routing: Routing | null;
    updated_at: string | null;
}

export interface RecordPage {
    rows: RecordRow[];
    page: number;
    pages: number;
    total: number;
}

export async function fetchRecords(query: { page: number; status?: Status; q?: string }): Promise<RecordPage> {
    const { data } = await http.get<unknown>(`${BASE}/records`, { params: { page: query.page, status: query.status || undefined, q: query.q || undefined } });
    if (!isObject(data) || !Array.isArray(data.data) || !isObject(data.meta)) {
        throw unexpected('subdomain list');
    }

    const rows: RecordRow[] = [];
    for (const item of data.data.filter(isObject)) {
        if (typeof item.id === 'number' && typeof item.address === 'string' && isStatus(item.status)) {
            const server = isObject(item.server) && typeof item.server.id === 'number' && typeof item.server.name === 'string' ? { id: item.server.id, name: item.server.name } : null;
            rows.push({
                id: item.id,
                label: String(item.label ?? ''),
                domain: String(item.domain ?? ''),
                address: item.address,
                status: item.status,
                last_error: typeof item.last_error === 'string' ? item.last_error : null,
                attempts: typeof item.attempts === 'number' ? item.attempts : 0,
                server,
                routing: parseRouting(item.routing),
                updated_at: typeof item.updated_at === 'string' ? item.updated_at : null,
            });
        }
    }

    return { rows, page: Number(data.meta.page) || 1, pages: Number(data.meta.pages) || 1, total: Number(data.meta.total) || 0 };
}

export async function retryRecord(id: number): Promise<void> {
    await http.post(`${BASE}/records/${id}/retry`);
}

export async function removeRecord(id: number): Promise<void> {
    await http.delete(`${BASE}/records/${id}`);
}

/** What the server console shows its owner about the server's address (the owner's API, not the admin one). */
export interface ServerAddress {
    address: string | null;
    status: string | null;
    mode: Mode;
    needs_port: boolean;
    routing: Routing | null;
}

/** One cache entry per server, shared by the console and the dashboard, so a page asks once. */
export const serverAddressKey = (uuid: string) => ['subdomain-manager', 'server-address', uuid] as const;

export async function fetchServerAddress(uuid: string): Promise<ServerAddress> {
    const { data } = await http.get<unknown>(`/api/client/servers/${uuid}/extensions/subdomain-manager/address`);
    if (!isObject(data)) {
        throw unexpected('server address');
    }

    return {
        address: typeof data.address === 'string' ? data.address : null,
        status: typeof data.status === 'string' ? data.status : null,
        mode: data.mode === 'routed' ? 'routed' : 'per_port',
        needs_port: data.needs_port === true,
        routing: parseRouting(data.routing),
    };
}
