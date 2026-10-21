import { http } from '@pterodactyl/sdk';

type Json = Record<string, unknown>;
const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value);
const unexpected = (what: string) => new Error(`The ${what} has an unexpected shape.`);

const base = (serverUuid: string) => `/api/client/servers/${serverUuid}/extensions/file-transfer`;

export interface ChunkBody {
    upload_id: string;
    index: number;
    total_chunks: number;
    filename: string;
    checksum: string;
    data: string;
}

export interface MergeBody {
    upload_id: string;
    filename: string;
    target_directory: string;
    total_checksum: string;
}

export async function uploadChunk(serverUuid: string, body: ChunkBody, signal?: AbortSignal): Promise<{ accepted: number; remaining: number }> {
    const { data } = await http.post<unknown>(`${base(serverUuid)}/chunk`, body, { signal });

    if (!isObject(data) || !Number.isInteger(data.accepted) || !Number.isInteger(data.remaining)) {
        throw unexpected('chunk answer');
    }

    return { accepted: data.accepted as number, remaining: data.remaining as number };
}

export async function mergeChunks(serverUuid: string, body: MergeBody, signal?: AbortSignal): Promise<void> {
    const { data } = await http.post<unknown>(`${base(serverUuid)}/chunk/merge`, body, { signal });

    if (!isObject(data) || data.uploaded !== true) {
        throw unexpected('merge answer');
    }
}

/** Starts a download on the Panel. Returns the id of the progress record to follow; the file name is optional. */
export async function remoteFetch(serverUuid: string, body: { url: string; target_directory: string; filename?: string }): Promise<string> {
    const { data } = await http.post<unknown>(`${base(serverUuid)}/remote-fetch`, body);

    if (!isObject(data) || typeof data.job_id !== 'string' || !/^[0-9a-f-]{36}$/i.test(data.job_id)) {
        throw unexpected('fetch answer');
    }

    return data.job_id;
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

/** The fixed error code the backend sent, such as "checksum_mismatch", or null. */
export function errorCode(error: unknown): string | null {
    const data = response(error)?.data;

    return isObject(data) && typeof data.error === 'string' ? data.error : null;
}

/** How long a rate limit says to wait, in milliseconds, from the Retry-After header (seconds). Null when it does not say. */
export function retryAfterMs(error: unknown): number | null {
    const headers = response(error)?.headers;
    const raw = isObject(headers) ? (headers['retry-after'] ?? headers['Retry-After']) : undefined;
    const seconds = typeof raw === 'string' || typeof raw === 'number' ? Number(raw) : Number.NaN;

    return Number.isFinite(seconds) && seconds >= 0 ? Math.ceil(seconds) * 1000 : null;
}

const FILE_NAME = { title: 'That file name cannot be used', body: 'Use only letters, digits, dots, hyphens and underscores, and at most 255 characters.' };
const UPLOAD_FAILED = { title: 'The server did not accept the file', body: 'The Panel could not write the file to the server. Check that the server has free disk space and that the folder still exists, then try again.' };
const NOT_FETCHABLE = { title: 'That address cannot be fetched', body: 'Use a public http or https address. Addresses inside a private network, and addresses with a user name or password, are not allowed.' };

/** What went wrong with a request, in this bundle's own words. Never a code, and never text the server sent. */
export function describeError(error: unknown): Message {
    const messages: Record<string, Message> = {
        invalid_filename: FILE_NAME,
        invalid_upload_id: { title: 'The upload could not be started', body: 'Start the upload again.' },
        invalid_target_directory: { title: 'That folder cannot be used', body: 'Open the folder in the file manager again and retry.' },
        invalid_url: NOT_FETCHABLE,
        file_too_large: { title: 'The file is too large', body: 'It is larger than the limit an administrator has set. Choose a smaller file.' },
        chunk_too_large: { title: 'The upload was cut into pieces that are too big', body: 'Reload the page and try again.' },
        invalid_chunk_data: { title: 'A piece of the file was damaged', body: 'Start the upload again.' },
        checksum_mismatch: { title: 'The file arrived damaged', body: 'What the server received is not what was sent. Start the upload again.' },
        upload_id_conflict: { title: 'The upload got out of step', body: 'Start the upload again.' },
        upload_not_found: { title: 'The upload got out of step', body: 'Start the upload again.' },
        chunks_missing: { title: 'Some pieces of the file did not arrive', body: 'Start the upload again.' },
        merge_in_progress: { title: 'This upload is already being finished', body: 'Wait a moment, then check the file list.' },
        upload_failed: UPLOAD_FAILED,
    };
    const code = errorCode(error);
    const status = statusOf(error);

    return (
        (code !== null ? messages[code] : undefined) ??
        (status === 403 ? { title: 'Not allowed', body: 'You do not have permission to do that on this server.' } : undefined) ??
        (status === 429 ? { title: 'Too many requests', body: 'The Panel limits how fast files can be sent. Wait a minute and try again.' } : undefined) ??
        { title: 'Something went wrong', body: 'Try again in a moment. If it keeps happening, tell an administrator.' }
    );
}

/** What a download that failed on the Panel means: the code that the progress record carries. */
export function describeFailure(code: string): Message {
    const messages: Record<string, Message> = {
        invalid_url: NOT_FETCHABLE,
        download_failed: { title: 'The download failed', body: 'The other server did not give the file. Check the address, and that the file is public, then try again.' },
        download_too_large: { title: 'The file is too big', body: 'It is larger than the limit an administrator has set for downloads.' },
        timeout: { title: 'The download took too long', body: 'The other server did not answer in time. Try again later.' },
        connection_refused: { title: 'The other server could not be reached', body: 'Check the address, then try again.' },
        upload_failed: UPLOAD_FAILED,
    };

    return messages[code] ?? { title: 'The download failed', body: 'Try again in a moment. If it keeps happening, tell an administrator.' };
}
