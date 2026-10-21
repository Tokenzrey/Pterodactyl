import { http } from '@pterodactyl/sdk';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { describeError, describeFailure, errorCode, mergeChunks, remoteFetch, retryAfterMs, statusOf, uploadChunk } from './api';

const UUID = '11111111-2222-4333-8444-555555555555';
const BASE = `/api/client/servers/${UUID}/extensions/file-transfer`;
const JOB = '99999999-8888-4777-8666-555555555555';

afterEach(() => vi.restoreAllMocks());

const failure = (status: number, data?: unknown, headers?: Record<string, unknown>) => ({ response: { status, data, headers } });

describe('uploadChunk', () => {
    const body = { upload_id: JOB, index: 0, total_chunks: 2, filename: 'a.zip', checksum: 'c', data: 'ZGF0YQ==' };

    it('posts the piece and returns what the Panel counted', async () => {
        vi.spyOn(http, 'post').mockResolvedValue({ data: { accepted: 0, remaining: 1 } } as never);

        await expect(uploadChunk(UUID, body)).resolves.toEqual({ accepted: 0, remaining: 1 });
        expect(http.post).toHaveBeenCalledWith(`${BASE}/chunk`, body, { signal: undefined });
    });

    it.each([[null], ['ok'], [{}], [{ accepted: '0', remaining: 1 }], [{ accepted: 0, remaining: 1.5 }]])('rejects an answer of the wrong shape: %j', async (data) => {
        vi.spyOn(http, 'post').mockResolvedValue({ data } as never);

        await expect(uploadChunk(UUID, body)).rejects.toThrow(/unexpected shape/);
    });
});

describe('mergeChunks', () => {
    const body = { upload_id: JOB, filename: 'a.zip', target_directory: '.', total_checksum: 'c' };

    it('posts to the merge endpoint', async () => {
        vi.spyOn(http, 'post').mockResolvedValue({ data: { uploaded: true } } as never);

        await mergeChunks(UUID, body);

        expect(http.post).toHaveBeenCalledWith(`${BASE}/chunk/merge`, body, { signal: undefined });
    });

    it.each([[null], [{}], [{ uploaded: false }], [{ uploaded: 'yes' }]])('does not call %j a success', async (data) => {
        vi.spyOn(http, 'post').mockResolvedValue({ data } as never);

        await expect(mergeChunks(UUID, body)).rejects.toThrow(/unexpected shape/);
    });
});

describe('remoteFetch', () => {
    it('returns the id of the progress record', async () => {
        vi.spyOn(http, 'post').mockResolvedValue({ data: { job_id: JOB } } as never);

        await expect(remoteFetch(UUID, { url: 'https://example.com/a.zip', target_directory: '.' })).resolves.toBe(JOB);
        expect(http.post).toHaveBeenCalledWith(`${BASE}/remote-fetch`, { url: 'https://example.com/a.zip', target_directory: '.' });
    });

    it.each([[null], [{}], [{ job_id: 5 }], [{ job_id: '../x' }], [{ job_id: `${JOB}/../..` }]])('refuses a job id that is not a UUID: %j', async (data) => {
        vi.spyOn(http, 'post').mockResolvedValue({ data } as never);

        await expect(remoteFetch(UUID, { url: 'https://example.com/a', target_directory: '.' })).rejects.toThrow(/unexpected shape/);
    });
});

describe('reading a failed request', () => {
    it('gets the status, or 0 when nothing answered', () => {
        expect(statusOf(failure(503))).toBe(503);
        expect(statusOf(new Error('Network Error'))).toBe(0);
        expect(statusOf(null)).toBe(0);
        expect(statusOf({ response: { status: '500' } })).toBe(0);
    });

    it('gets the error code the backend sent, and only a string one', () => {
        expect(errorCode(failure(422, { error: 'checksum_mismatch' }))).toBe('checksum_mismatch');
        expect(errorCode(failure(422, { error: 5 }))).toBeNull();
        expect(errorCode(failure(422, 'text'))).toBeNull();
        expect(errorCode(new Error('x'))).toBeNull();
    });

    it.each([
        ['7', 7000],
        [7, 7000],
        ['0', 0],
        ['1.2', 2000],
    ])('reads Retry-After %j as %i ms', (value, expected) => {
        expect(retryAfterMs(failure(429, undefined, { 'retry-after': value }))).toBe(expected);
        expect(retryAfterMs(failure(429, undefined, { 'Retry-After': value }))).toBe(expected);
    });

    it.each([[undefined], ['soon'], ['-3'], [null]])('has no wait for a Retry-After of %j', (value) => {
        expect(retryAfterMs(failure(429, undefined, value === undefined ? {} : { 'retry-after': value }))).toBeNull();
        expect(retryAfterMs(new Error('x'))).toBeNull();
    });
});

describe('describeError', () => {
    const CODES = [
        'invalid_filename',
        'invalid_upload_id',
        'invalid_target_directory',
        'invalid_url',
        'file_too_large',
        'chunk_too_large',
        'invalid_chunk_data',
        'checksum_mismatch',
        'upload_id_conflict',
        'upload_not_found',
        'chunks_missing',
        'merge_in_progress',
        'upload_failed',
    ];

    it.each(CODES)('has words for the code %s that are not the code itself', (code) => {
        const message = describeError(failure(422, { error: code }));

        expect(message.title).not.toBe('Something went wrong');
        expect(`${message.title} ${message.body}`).not.toContain(code);
    });

    it('names a missing permission', () => {
        expect(describeError(failure(403)).title).toBe('Not allowed');
    });

    it('explains a rate limit', () => {
        expect(describeError(failure(429)).title).toBe('Too many requests');
    });

    it('falls back to a general message and never shows text the server sent', () => {
        const message = describeError(failure(500, { error: 'boom', message: '<script>alert(1)</script> SQLSTATE[HY000]' }));

        expect(message.title).toBe('Something went wrong');
        expect(JSON.stringify(message)).not.toContain('SQLSTATE');
        expect(describeError(new Error('Network Error')).title).toBe('Something went wrong');
    });
});

describe('describeFailure', () => {
    it.each(['invalid_url', 'download_failed', 'download_too_large', 'timeout', 'connection_refused', 'upload_failed'])('has words for %s', (code) => {
        const message = describeFailure(code);

        expect(message.title.length).toBeGreaterThan(0);
        expect(`${message.title} ${message.body}`).not.toContain(code);
    });

    it('answers an unknown code in general terms', () => {
        expect(describeFailure('something_new').title).toBe('The download failed');
    });
});
