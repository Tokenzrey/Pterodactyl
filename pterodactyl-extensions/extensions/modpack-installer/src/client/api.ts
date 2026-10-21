import { http } from '@pterodactyl/sdk';

type Json = Record<string, unknown>;
const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value);
const isString = (value: unknown): value is string => typeof value === 'string';
const isNumber = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value);
const isBoolean = (value: unknown): value is boolean => typeof value === 'boolean';
const unexpected = (what: string) => new Error(`The ${what} has an unexpected shape.`);

const base = (serverUuid: string) => `/api/client/servers/${serverUuid}/extensions/modpack-installer`;

/** The number of results a page holds, for both sources. */
export const PAGE_SIZE = 20;

export type Source = 'curseforge' | 'modrinth';
export type Loader = 'forge' | 'fabric' | 'quilt' | 'neoforge';

export const LOADERS: readonly Loader[] = ['forge', 'fabric', 'quilt', 'neoforge'];

export interface ModpackFile {
    file_id: string;
    name: string;
    game_version: string | null;
    loader: string | null;
    is_server_pack: boolean;
    file_size_mb: number | null;
}

export const isModpackFile = (value: unknown): value is ModpackFile =>
    isObject(value) &&
    isString(value.file_id) &&
    isString(value.name) &&
    isBoolean(value.is_server_pack) &&
    (value.game_version === null || isString(value.game_version)) &&
    (value.loader === null || isString(value.loader)) &&
    (value.file_size_mb === null || isNumber(value.file_size_mb));

export interface ModpackResult {
    source: Source;
    project_id: string;
    name: string;
    summary: string;
    downloads: number;
    icon_url: string | null;
    latest_files: ModpackFile[];
}

export const isModpackResult = (value: unknown): value is ModpackResult =>
    isObject(value) &&
    (value.source === 'curseforge' || value.source === 'modrinth') &&
    isString(value.project_id) &&
    isString(value.name) &&
    isString(value.summary) &&
    isNumber(value.downloads) &&
    (value.icon_url === null || isString(value.icon_url)) &&
    Array.isArray(value.latest_files);

export interface SearchResponse {
    results: ModpackResult[];
    total: number;
    page: number;
}

export interface SearchCriteria {
    source: Source;
    query: string;
    game_version?: string;
    loader?: Loader;
}

export async function searchModpacks(serverUuid: string, criteria: SearchCriteria, page: number, signal?: AbortSignal): Promise<SearchResponse> {
    const { data } = await http.get<unknown>(`${base(serverUuid)}/search`, { params: { ...criteria, page }, signal });

    if (!isObject(data) || !Array.isArray(data.results) || !isNumber(data.total) || !isNumber(data.page)) {
        throw unexpected('search answer');
    }

    // A result or a file the screen cannot read is left out, not allowed to break the page.
    return {
        results: data.results.filter(isModpackResult).map((result) => ({ ...result, latest_files: result.latest_files.filter(isModpackFile) })),
        total: data.total,
        page: data.page,
    };
}

export interface InstallBody {
    source: Source;
    project_id: string;
    file_id: string;
    target_directory?: string;
}

/** Starts the installation on the Panel. Returns the id of the progress record to follow. */
export async function installModpack(serverUuid: string, body: InstallBody): Promise<string> {
    const { data } = await http.post<unknown>(`${base(serverUuid)}/install`, body);

    if (!isObject(data) || !isString(data.job_id) || !/^[0-9a-f-]{36}$/i.test(data.job_id)) {
        throw unexpected('install answer');
    }

    return data.job_id;
}

/** The folder the pack goes into, as typed: empty is the server's main folder. Null when it is acceptable, otherwise why not. */
export function folderError(folder: string): string | null {
    if (folder === '') {
        return null;
    }
    if (folder.length > 255) {
        return 'Use at most 255 characters.';
    }
    if (folder.startsWith('/')) {
        return 'Leave out the first slash: the folder is inside the server.';
    }
    if (folder.includes('..') || folder.includes('//')) {
        return 'A folder name cannot contain ".." or "//".';
    }
    if (!/^[A-Za-z0-9_\-/.]+$/.test(folder)) {
        return 'Use only letters, digits, dots, hyphens, underscores and slashes.';
    }

    return null;
}

/** The Minecraft version filter, as the Panel accepts it. Empty means no filter. */
export const isGameVersion = (value: string): boolean => /^[0-9A-Za-z.-]{0,20}$/.test(value);

export function formatSize(megabytes: number | null): string | null {
    if (megabytes === null) {
        return null;
    }

    return megabytes >= 1024 ? `${Number((megabytes / 1024).toFixed(1))} GB` : `${Number(megabytes.toFixed(1))} MB`;
}

export interface Message {
    title: string;
    body: string;
}

const response = (error: unknown): Json | null => (isObject(error) && isObject(error.response) ? error.response : null);

/** The HTTP status of a failed request, or 0 when there was no answer at all (the network, or a cancelled request). */
export function statusOf(error: unknown): number {
    const status = response(error)?.status;

    return typeof status === 'number' ? status : 0;
}

/** The fixed error code the backend sent, such as "install_in_progress", or null. */
export function errorCode(error: unknown): string | null {
    const data = response(error)?.data;

    return isObject(data) && typeof data.error === 'string' ? data.error : null;
}

const ASK_ADMIN = 'Try again in a moment. If it keeps happening, tell an administrator.';

/** What went wrong with a request, in this bundle's own words. Never a code, and never text the server sent. */
export function describeError(error: unknown): Message {
    const messages: Record<string, Message> = {
        curseforge_not_configured: { title: 'CurseForge is not set up', body: 'An administrator needs to add a CurseForge API key in this extension’s settings. Modrinth can be searched without one.' },
        source_unavailable: { title: 'The modpack source is not answering', body: 'CurseForge or Modrinth could not be reached. Try again in a moment.' },
        not_server_pack: { title: 'This is not a server pack', body: 'Only a server pack can be installed on a server. Pick one marked as a server pack.' },
        file_not_found: { title: 'That file is gone', body: 'CurseForge no longer has it. Search again to see what is available.' },
        download_not_allowed: { title: 'The author does not allow this download', body: 'This pack can only be downloaded from the CurseForge site itself, so it cannot be installed from here.' },
        download_too_large: { title: 'That pack is too large', body: 'It is bigger than the limit an administrator has set for downloads.' },
        invalid_target_directory: { title: 'That folder cannot be used', body: 'Use a folder name inside the server, without ".." or a first slash.' },
        invalid_id: { title: 'That pack could not be identified', body: 'Search again and pick it from the list.' },
        install_in_progress: { title: 'This pack is already being installed', body: 'Wait for the installation that is running to finish.' },
        invalid_query: { title: 'Type something to search for', body: 'The search needs at least one letter.' },
        invalid_page: { title: 'That page does not exist', body: 'Go back to the first page.' },
    };
    const code = errorCode(error);
    const status = statusOf(error);

    return (
        (code !== null && Object.hasOwn(messages, code) ? messages[code] : undefined) ??
        (status === 403 ? { title: 'Not allowed', body: 'You do not have permission to install modpacks on this server.' } : undefined) ??
        (status === 422 ? { title: 'Those values cannot be saved', body: 'Check the Minecraft version (digits, dots and hyphens only) and the loader.' } : undefined) ??
        (status === 429 ? { title: 'Too many requests', body: 'Wait a minute and try again.' } : undefined) ??
        { title: 'Something went wrong', body: ASK_ADMIN }
    );
}

/** What an installation that failed on the Panel means: the code that its progress record carries. */
export function describeFailure(code: string): Message {
    const messages: Record<string, Message> = {
        source_unavailable: { title: 'The modpack source did not answer', body: 'CurseForge could not be reached. Try again later.' },
        file_not_found: { title: 'That file is gone', body: 'CurseForge no longer has it. Search again.' },
        not_server_pack: { title: 'This is not a server pack', body: 'Pick a file that is marked as a server pack.' },
        download_failed: { title: 'The download failed', body: 'The pack could not be downloaded, or it did not arrive intact. Try again later.' },
        download_too_large: { title: 'That pack is too large', body: 'It is bigger than the limit an administrator has set for downloads.' },
        upload_failed: { title: 'The server did not accept the pack', body: 'Check that the server has free disk space and that the folder still exists, then try again.' },
        extract_failed: { title: 'The pack could not be unpacked', body: 'The archive may be damaged, or the server is out of disk space. Some files may already be in the folder.' },
        sanitize_failed: { title: 'The pack is installed, but cleanup failed', body: 'Some launch scripts could not be removed. Delete start.sh, run.bat and similar files in the folder yourself.' },
        disk_full: { title: 'The Panel has no room for the pack', body: 'Tell an administrator that the Panel’s disk is full.' },
    };

    return (Object.hasOwn(messages, code) ? messages[code] : undefined) ?? { title: 'The installation failed', body: ASK_ADMIN };
}

/** What a server's search opens with, as the Panel stores it (plan 12, "Pengaturan per-server"). */
export interface ServerDefaults {
    default_source: Source;
    default_game_version: string;
    default_loader: Loader | '';
}

export const isServerDefaults = (value: unknown): value is ServerDefaults =>
    isObject(value) &&
    (value.default_source === 'curseforge' || value.default_source === 'modrinth') &&
    isString(value.default_game_version) &&
    (value.default_loader === '' || (typeof value.default_loader === 'string' && (LOADERS as readonly string[]).includes(value.default_loader)));

/** What the search starts from when no defaults were saved, or when they cannot be read. CurseForge, because only it can install. */
export const FALLBACK_DEFAULTS: ServerDefaults = { default_source: 'curseforge', default_game_version: '', default_loader: '' };

export async function getServerDefaults(serverUuid: string, signal?: AbortSignal): Promise<ServerDefaults> {
    const { data } = await http.get<unknown>(`${base(serverUuid)}/defaults`, { signal });

    if (!isServerDefaults(data)) {
        throw unexpected('defaults answer');
    }

    return data;
}

export async function saveServerDefaults(serverUuid: string, body: ServerDefaults): Promise<ServerDefaults> {
    const { data } = await http.put<unknown>(`${base(serverUuid)}/defaults`, body);

    if (!isServerDefaults(data)) {
        throw unexpected('defaults answer');
    }

    return data;
}
