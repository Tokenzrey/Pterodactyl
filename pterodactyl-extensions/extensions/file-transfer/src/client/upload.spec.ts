import { createHash, randomBytes } from 'node:crypto';
import { http } from '@pterodactyl/sdk';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MAX_RETRIES, readBytes, uploadFile, UploadCancelled, uuidV4, type UploadProgress } from './upload';

// The client half of the chunked upload contract: every piece carries its own checksum, the merge carries the checksum of
// the whole file, and a flaky network or a rate limit does not lose the upload.

const UUID = '11111111-2222-4333-8444-555555555555';
const sha = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
const noWait = vi.fn(async (_ms: number) => {});

interface Call {
    url: string;
    body: Record<string, unknown>;
}

/** Answers every post with success and remembers what was sent, in order. */
function acceptAll(): Call[] {
    const calls: Call[] = [];
    vi.spyOn(http, 'post').mockImplementation(async (url: string, body?: unknown) => {
        calls.push({ url, body: body as Record<string, unknown> });

        return { data: String(url).endsWith('/merge') ? { uploaded: true } : { accepted: (body as { index: number }).index, remaining: 0 } };
    });

    return calls;
}

const failure = (status: number, data?: unknown, headers?: Record<string, unknown>) => ({ response: { status, data, headers } });
const run = (file: Blob, extra: Partial<Parameters<typeof uploadFile>[0]> = {}) =>
    uploadFile({ serverUuid: UUID, file, filename: 'a.bin', directory: 'plugins', chunkBytes: 1000, sleep: noWait, ...extra });

afterEach(() => {
    vi.restoreAllMocks();
    noWait.mockClear();
});

describe('uuidV4', () => {
    it('makes version 4 UUIDs that differ', () => {
        const ids = new Set(Array.from({ length: 50 }, uuidV4));

        expect(ids.size).toBe(50);
        for (const id of ids) {
            expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
        }
    });
});

describe('readBytes', () => {
    it('reads a blob whole', async () => {
        const bytes = new Uint8Array(randomBytes(300));

        expect(await readBytes(new Blob([bytes]))).toEqual(bytes);
    });

    it('reads through a FileReader where Blob.arrayBuffer() does not exist', async () => {
        const bytes = new Uint8Array(randomBytes(300));
        const blob = new Blob([bytes]);
        Object.defineProperty(blob, 'arrayBuffer', { value: undefined });

        expect(await readBytes(blob)).toEqual(bytes);
    });
});

describe('uploadFile', () => {
    it('cuts the file into pieces, each with its own checksum and the right position', async () => {
        const calls = acceptAll();
        const data = new Uint8Array(randomBytes(2500));

        await run(new Blob([data]));

        const pieces = calls.filter((call) => call.url.endsWith('/chunk'));
        expect(pieces).toHaveLength(3);
        pieces.forEach((call, index) => {
            const piece = data.subarray(index * 1000, Math.min(2500, (index + 1) * 1000));
            expect(call.url).toBe(`/api/client/servers/${UUID}/extensions/file-transfer/chunk`);
            expect(call.body).toMatchObject({ index, total_chunks: 3, filename: 'a.bin', checksum: sha(piece) });
            expect(Buffer.from(call.body.data as string, 'base64')).toEqual(Buffer.from(piece));
        });
    });

    it('uses one upload id for every piece and the merge', async () => {
        const calls = acceptAll();

        await run(new Blob([randomBytes(2500)]));

        expect(new Set(calls.map((call) => call.body.upload_id)).size).toBe(1);
        expect(calls[0].body.upload_id).toMatch(/^[0-9a-f-]{36}$/);
    });

    it('finishes with a merge carrying the checksum of the whole file and the target folder', async () => {
        const calls = acceptAll();
        const data = new Uint8Array(randomBytes(2500));

        await run(new Blob([data]));

        const merge = calls.at(-1)!;
        expect(merge.url).toBe(`/api/client/servers/${UUID}/extensions/file-transfer/chunk/merge`);
        expect(merge.body).toMatchObject({ filename: 'a.bin', target_directory: 'plugins', total_checksum: sha(data) });
    });

    it('sends an empty file as one empty piece, since the backend wants at least one', async () => {
        const calls = acceptAll();

        await run(new Blob([]));

        const pieces = calls.filter((call) => call.url.endsWith('/chunk'));
        expect(pieces).toHaveLength(1);
        expect(pieces[0].body).toMatchObject({ total_chunks: 1, data: '', checksum: sha(new Uint8Array()) });
        expect(calls.at(-1)!.body.total_checksum).toBe(sha(new Uint8Array()));
    });

    it('sends a file that is exactly one piece long as one piece', async () => {
        const calls = acceptAll();

        await run(new Blob([randomBytes(1000)]));

        expect(calls.filter((call) => call.url.endsWith('/chunk'))).toHaveLength(1);
    });

    it('reports progress per piece, then that it is finishing', async () => {
        acceptAll();
        const seen: UploadProgress[] = [];

        await run(new Blob([randomBytes(2500)]), { onProgress: (progress) => seen.push(progress) });

        expect(seen).toEqual([
            { sent: 1000, total: 2500, chunk: 1, chunks: 3, phase: 'uploading' },
            { sent: 2000, total: 2500, chunk: 2, chunks: 3, phase: 'uploading' },
            { sent: 2500, total: 2500, chunk: 3, chunks: 3, phase: 'uploading' },
            { sent: 2500, total: 2500, chunk: 3, chunks: 3, phase: 'finishing' },
        ]);
    });

    describe('when the network or the Panel fails', () => {
        it('sends a piece again after a network error, with the same body', async () => {
            const bodies: unknown[] = [];
            vi.spyOn(http, 'post').mockImplementation(async (url: string, body?: unknown) => {
                if (String(url).endsWith('/merge')) {
                    return { data: { uploaded: true } };
                }
                bodies.push(body);
                if (bodies.length === 1) {
                    throw new Error('Network Error');
                }

                return { data: { accepted: 0, remaining: 0 } };
            });

            await run(new Blob([randomBytes(500)]));

            expect(bodies).toHaveLength(2);
            expect(bodies[1]).toEqual(bodies[0]);
            expect(noWait).toHaveBeenCalledWith(1000);
        });

        it('waits longer after each failure, and gives up after the last allowed retry', async () => {
            const post = vi.spyOn(http, 'post').mockRejectedValue(failure(503, { error: 'x' }));

            await expect(run(new Blob([randomBytes(500)]))).rejects.toMatchObject({ response: { status: 503 } });

            expect(post).toHaveBeenCalledTimes(MAX_RETRIES + 1);
            expect(noWait.mock.calls.map(([ms]) => ms)).toEqual([1000, 2000, 4000]);
        });

        it('does not retry an answer that will not change, such as a checksum mismatch', async () => {
            const post = vi.spyOn(http, 'post').mockRejectedValue(failure(422, { error: 'checksum_mismatch' }));

            await expect(run(new Blob([randomBytes(500)]))).rejects.toMatchObject({ response: { status: 422 } });

            expect(post).toHaveBeenCalledTimes(1);
            expect(noWait).not.toHaveBeenCalled();
        });

        it.each([403, 404, 413])('does not retry a %i', async (status) => {
            const post = vi.spyOn(http, 'post').mockRejectedValue(failure(status));

            await expect(run(new Blob([randomBytes(500)]))).rejects.toBeDefined();

            expect(post).toHaveBeenCalledTimes(1);
        });

        it('waits as long as the Panel says after a 429, then carries on', async () => {
            let first = true;
            vi.spyOn(http, 'post').mockImplementation(async (url: string) => {
                if (first && !String(url).endsWith('/merge')) {
                    first = false;
                    throw failure(429, undefined, { 'retry-after': '12' });
                }

                return { data: String(url).endsWith('/merge') ? { uploaded: true } : { accepted: 0, remaining: 0 } };
            });

            await run(new Blob([randomBytes(500)]));

            expect(noWait).toHaveBeenCalledWith(12_000);
        });

        it('caps a very long Retry-After at a minute', async () => {
            let first = true;
            vi.spyOn(http, 'post').mockImplementation(async (url: string) => {
                if (first) {
                    first = false;
                    throw failure(429, undefined, { 'retry-after': '86400' });
                }

                return { data: String(url).endsWith('/merge') ? { uploaded: true } : { accepted: 0, remaining: 0 } };
            });

            await run(new Blob([randomBytes(500)]));

            expect(noWait).toHaveBeenCalledWith(60_000);
        });

        it('stops waiting out a rate limit that never lifts', async () => {
            const post = vi.spyOn(http, 'post').mockRejectedValue(failure(429, undefined, { 'retry-after': '1' }));

            await expect(run(new Blob([randomBytes(500)]))).rejects.toMatchObject({ response: { status: 429 } });

            expect(post).toHaveBeenCalledTimes(11);
        });

        it('does not retry a merge that the server refused, so the message is shown at once', async () => {
            const post = vi.spyOn(http, 'post').mockImplementation(async (url: string) => {
                if (String(url).endsWith('/merge')) {
                    throw failure(503, { error: 'upload_failed' });
                }

                return { data: { accepted: 0, remaining: 0 } };
            });

            await expect(run(new Blob([randomBytes(500)]))).rejects.toMatchObject({ response: { status: 503 } });

            expect(post).toHaveBeenCalledTimes(2);
        });

        it('does not send the merge when a piece has failed for good', async () => {
            const post = vi.spyOn(http, 'post').mockRejectedValue(failure(422, { error: 'invalid_chunk_data' }));

            await expect(run(new Blob([randomBytes(2500)]))).rejects.toBeDefined();

            expect(post.mock.calls.some(([url]) => String(url).endsWith('/merge'))).toBe(false);
            expect(post).toHaveBeenCalledTimes(1);
        });
    });

    describe('when cancelled', () => {
        it('stops before the next piece and never merges', async () => {
            const controller = new AbortController();
            const calls: string[] = [];
            vi.spyOn(http, 'post').mockImplementation(async (url: string) => {
                calls.push(String(url));
                controller.abort();

                return { data: { accepted: 0, remaining: 1 } };
            });

            await expect(run(new Blob([randomBytes(2500)]), { signal: controller.signal })).rejects.toBeInstanceOf(UploadCancelled);

            expect(calls).toHaveLength(1);
        });

        it('does not start when already cancelled', async () => {
            const controller = new AbortController();
            controller.abort();
            const post = vi.spyOn(http, 'post');

            await expect(run(new Blob([randomBytes(10)]), { signal: controller.signal })).rejects.toBeInstanceOf(UploadCancelled);

            expect(post).not.toHaveBeenCalled();
        });

        it('treats a request that fails because of the cancel as a cancel, not as a network error to retry', async () => {
            const controller = new AbortController();
            const post = vi.spyOn(http, 'post').mockImplementation(async () => {
                controller.abort();
                throw new Error('canceled');
            });

            await expect(run(new Blob([randomBytes(10)]), { signal: controller.signal })).rejects.toBeInstanceOf(UploadCancelled);

            expect(post).toHaveBeenCalledTimes(1);
            expect(noWait).not.toHaveBeenCalled();
        });

        it('passes the signal on to every request', async () => {
            const controller = new AbortController();
            const post = vi.spyOn(http, 'post').mockImplementation(async (url: string) => ({ data: String(url).endsWith('/merge') ? { uploaded: true } : { accepted: 0, remaining: 0 } }));

            await run(new Blob([randomBytes(10)]), { signal: controller.signal });

            for (const call of post.mock.calls) {
                expect(call[2]).toEqual({ signal: controller.signal });
            }
        });
    });
});
