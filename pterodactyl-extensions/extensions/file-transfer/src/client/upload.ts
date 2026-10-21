import { mergeChunks, retryAfterMs, statusOf, uploadChunk } from './api';
import { toBase64 } from './base64';
import { Sha256, sha256Hex } from './sha256';

export const MIB = 1024 * 1024;

export interface UploadProgress {
    /** Bytes of the file sent so far. */
    sent: number;
    total: number;
    /** Pieces sent so far, of `chunks`. */
    chunk: number;
    chunks: number;
    /** "uploading" while pieces go out; "finishing" while the Panel joins them and hands the file to the server. */
    phase: 'uploading' | 'finishing';
}

export interface UploadOptions {
    serverUuid: string;
    file: Blob;
    /** The name to save the file under, already checked with isValidFileName. */
    filename: string;
    /** Relative to the server's root, "." for the root (see relativeDirectory). */
    directory: string;
    chunkBytes: number;
    signal?: AbortSignal;
    onProgress?: (progress: UploadProgress) => void;
    /** Waits between attempts. Tests replace it so they do not wait. */
    sleep?: (ms: number) => Promise<void>;
}

/** Network failures and 5xx answers are tried again this many times. */
export const MAX_RETRIES = 3;
/** A rate limit is waited out this many times in a row before the upload gives up. */
const MAX_RATE_WAITS = 10;
const DEFAULT_RATE_WAIT_MS = 5000;
const MAX_RATE_WAIT_MS = 60_000;

const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

export class UploadCancelled extends Error {
    constructor() {
        super('The upload was cancelled.');
        this.name = 'UploadCancelled';
    }
}

/** A version 4 UUID from the browser's random source. crypto.randomUUID() needs a secure context; this does not. */
export function uuidV4(): string {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');

    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** The bytes of a Blob. jsdom has no Blob.arrayBuffer(), so a FileReader stands in where it is missing. */
export async function readBytes(blob: Blob): Promise<Uint8Array> {
    if (typeof blob.arrayBuffer === 'function') {
        return new Uint8Array(await blob.arrayBuffer());
    }

    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(new Uint8Array(reader.result as ArrayBuffer));
        reader.onerror = () => reject(reader.error ?? new Error('The file could not be read.'));
        reader.readAsArrayBuffer(blob);
    });
}

/**
 * Runs one request, trying again as the answer allows: a network failure or a 5xx up to MAX_RETRIES times with a growing
 * pause (when `retryServerErrors`), a 429 after the pause the Panel asks for. Anything else is final, and so is a cancel.
 */
async function attempt<T>(run: () => Promise<T>, signal: AbortSignal | undefined, sleep: (ms: number) => Promise<void>, retryServerErrors: boolean): Promise<T> {
    let failures = 0;
    let rateWaits = 0;

    for (;;) {
        if (signal?.aborted) {
            throw new UploadCancelled();
        }

        try {
            return await run();
        } catch (error) {
            if (signal?.aborted) {
                throw new UploadCancelled();
            }

            const status = statusOf(error);
            if (status === 429 && rateWaits < MAX_RATE_WAITS) {
                rateWaits++;
                await sleep(Math.min(retryAfterMs(error) ?? DEFAULT_RATE_WAIT_MS, MAX_RATE_WAIT_MS));
            } else if (retryServerErrors && (status === 0 || status >= 500) && failures < MAX_RETRIES) {
                failures++;
                await sleep(1000 * 2 ** (failures - 1));
            } else {
                throw error;
            }
        }
    }
}

/**
 * Sends a file in pieces and has the Panel join them. Each piece is read once: its checksum is taken, it is added to the
 * checksum of the whole file, and it goes out as base64. Memory use stays at about one piece, whatever the file's size.
 * Rejects with UploadCancelled when the signal fires, otherwise with the failed request's error (see describeError).
 */
export async function uploadFile(options: UploadOptions): Promise<void> {
    const { serverUuid, file, filename, directory, chunkBytes, signal, onProgress } = options;
    const sleep = options.sleep ?? wait;
    const uploadId = uuidV4();
    const total = file.size;
    const chunks = Math.max(1, Math.ceil(total / chunkBytes));
    const whole = new Sha256();
    let sent = 0;

    for (let index = 0; index < chunks; index++) {
        if (signal?.aborted) {
            throw new UploadCancelled();
        }

        const bytes = await readBytes(file.slice(index * chunkBytes, Math.min(total, (index + 1) * chunkBytes)));
        whole.update(bytes);
        const body = { upload_id: uploadId, index, total_chunks: chunks, filename, checksum: sha256Hex(bytes), data: toBase64(bytes) };

        await attempt(() => uploadChunk(serverUuid, body, signal), signal, sleep, true);

        sent += bytes.length;
        onProgress?.({ sent, total, chunk: index + 1, chunks, phase: 'uploading' });
    }

    onProgress?.({ sent, total, chunk: chunks, chunks, phase: 'finishing' });
    const merge = { upload_id: uploadId, filename, target_directory: directory, total_checksum: whole.hex() };
    // A failed merge is not tried again on a server error: its message says the server refused the file, and a repeat would only wait for the same answer.
    await attempt(() => mergeChunks(serverUuid, merge, signal), signal, sleep, false);
}
