import { http } from '@pterodactyl/sdk';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { describeError, describeFailure, errorCode, folderError, formatSize, getServerDefaults, installModpack, isGameVersion, isModpackFile, isModpackResult, isServerDefaults, saveServerDefaults, searchModpacks, statusOf } from './api';

const UUID = '11111111-2222-4333-8444-555555555555';
const BASE = `/api/client/servers/${UUID}/extensions/modpack-installer`;
const JOB = '99999999-8888-4777-8666-555555555555';

afterEach(() => vi.restoreAllMocks());

const file = (over: Record<string, unknown> = {}) => ({ file_id: '4002', name: 'atm9.zip', game_version: '1.20.1', loader: 'forge', is_server_pack: true, file_size_mb: 12.5, ...over });
const result = (over: Record<string, unknown> = {}) => ({ source: 'curseforge', project_id: '123', name: 'ATM9', summary: 'All', downloads: 10, icon_url: null, latest_files: [file()], ...over });
const failure = (status: number, data?: unknown) => ({ response: { status, data } });

describe('searchModpacks', () => {
    it('asks the Panel for the search, with the criteria and the page, and hands on the signal', async () => {
        const get = vi.spyOn(http, 'get').mockResolvedValue({ data: { results: [result()], total: 1, page: 2 } } as never);
        const signal = new AbortController().signal;

        const answer = await searchModpacks(UUID, { source: 'curseforge', query: 'atm', game_version: '1.20.1', loader: 'forge' }, 2, signal);

        expect(get).toHaveBeenCalledWith(`${BASE}/search`, { params: { source: 'curseforge', query: 'atm', game_version: '1.20.1', loader: 'forge', page: 2 }, signal });
        expect(answer.total).toBe(1);
        expect(answer.page).toBe(2);
        expect(answer.results[0].name).toBe('ATM9');
    });

    it('leaves out a result or a file it cannot read, instead of failing the page', async () => {
        vi.spyOn(http, 'get').mockResolvedValue({
            data: { results: [result({ latest_files: [file(), { file_id: 5 }, 'text'] }), { name: 'no id' }, 'text', result({ source: 'github' })], total: 4, page: 0 },
        } as never);

        const answer = await searchModpacks(UUID, { source: 'curseforge', query: 'a' }, 0);

        expect(answer.results).toHaveLength(1);
        expect(answer.results[0].latest_files).toHaveLength(1);
    });

    it.each([[null], ['text'], [{}], [{ results: 'x', total: 1, page: 0 }], [{ results: [], total: '1', page: 0 }], [{ results: [], total: 1 }]])('rejects an answer of the wrong shape: %j', async (data) => {
        vi.spyOn(http, 'get').mockResolvedValue({ data } as never);

        await expect(searchModpacks(UUID, { source: 'curseforge', query: 'a' }, 0)).rejects.toThrow(/unexpected shape/);
    });
});

describe('installModpack', () => {
    it('posts the ids and the folder, and returns the id of the record to follow', async () => {
        const post = vi.spyOn(http, 'post').mockResolvedValue({ data: { job_id: JOB } } as never);

        await expect(installModpack(UUID, { source: 'curseforge', project_id: '123', file_id: '4002', target_directory: 'packs' })).resolves.toBe(JOB);
        expect(post).toHaveBeenCalledWith(`${BASE}/install`, { source: 'curseforge', project_id: '123', file_id: '4002', target_directory: 'packs' });
    });

    it.each([[null], [{}], [{ job_id: 5 }], [{ job_id: '../x' }], [{ job_id: `${JOB}/../..` }]])('refuses a job id that is not a UUID: %j', async (data) => {
        vi.spyOn(http, 'post').mockResolvedValue({ data } as never);

        await expect(installModpack(UUID, { source: 'curseforge', project_id: '1', file_id: '2' })).rejects.toThrow(/unexpected shape/);
    });
});

describe('type guards', () => {
    it('accept what the Panel sends', () => {
        expect(isModpackFile(file())).toBe(true);
        expect(isModpackFile(file({ game_version: null, loader: null, file_size_mb: null }))).toBe(true);
        expect(isModpackResult(result())).toBe(true);
        expect(isModpackResult(result({ source: 'modrinth', icon_url: 'https://cdn.modrinth.com/a.png' }))).toBe(true);
    });

    it.each([[{ is_server_pack: 'yes' }], [{ file_size_mb: '12' }], [{ name: 5 }], [{ loader: 3 }]])('refuse a file that is off: %j', (over) => {
        expect(isModpackFile(file(over))).toBe(false);
    });

    it.each([[{ source: 'github' }], [{ downloads: Number.NaN }], [{ latest_files: 'x' }], [{ icon_url: 5 }]])('refuse a result that is off: %j', (over) => {
        expect(isModpackResult(result(over))).toBe(false);
    });
});

describe('folderError (FR-MI19)', () => {
    it.each(['', 'packs', 'packs/atm9', 'a-b_c.d', '.', 'a'.repeat(255)])('accepts %j', (folder) => {
        expect(folderError(folder)).toBeNull();
    });

    it.each(['/', '/etc', '..', '../etc', 'a/../b', 'a//b', 'a b', 'a;b', 'a\\b', 'café', 'a\nb', 'a'.repeat(256)])('refuses %j, with a reason', (folder) => {
        expect(folderError(folder)).toEqual(expect.any(String));
    });
});

describe('isGameVersion', () => {
    it.each(['', '1.20.1', '1.20.1-pre1', '24w14a', 'a'.repeat(20)])('accepts %j', (value) => {
        expect(isGameVersion(value)).toBe(true);
    });

    it.each(['1.20&gameId=1', '1 20', 'a'.repeat(21), '1.20\n', '../x'])('refuses %j', (value) => {
        expect(isGameVersion(value)).toBe(false);
    });
});

describe('formatSize', () => {
    it.each([
        [null, null],
        [0, '0 MB'],
        [12.5, '12.5 MB'],
        [250.04, '250 MB'],
        [1024, '1 GB'],
        [1536, '1.5 GB'],
    ])('writes %s as %s', (megabytes, expected) => {
        expect(formatSize(megabytes)).toBe(expected);
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
        expect(errorCode(failure(422, { error: 'not_server_pack' }))).toBe('not_server_pack');
        expect(errorCode(failure(422, { error: 5 }))).toBeNull();
        expect(errorCode(failure(422, 'text'))).toBeNull();
        expect(errorCode(new Error('x'))).toBeNull();
    });
});

describe('describeError', () => {
    const CODES = [
        'curseforge_not_configured',
        'source_unavailable',
        'not_server_pack',
        'file_not_found',
        'download_not_allowed',
        'download_too_large',
        'invalid_target_directory',
        'invalid_id',
        'install_in_progress',
        'invalid_query',
        'invalid_page',
    ];

    it.each(CODES)('has words for %s that are not the code itself', (code) => {
        const message = describeError(failure(422, { error: code }));

        expect(message.title).not.toBe('Something went wrong');
        expect(`${message.title} ${message.body}`).not.toContain(code);
    });

    it('tells an admin’s job from a user’s: a missing key is for the administrator', () => {
        expect(describeError(failure(503, { error: 'curseforge_not_configured' })).body).toMatch(/administrator/);
    });

    it('names a missing permission and a rate limit', () => {
        expect(describeError(failure(403)).title).toBe('Not allowed');
        expect(describeError(failure(429)).title).toBe('Too many requests');
    });

    it('falls back to a general message, and never shows text the server sent', () => {
        const message = describeError(failure(500, { error: 'boom', message: '<script>alert(1)</script> SQLSTATE[HY000]' }));

        expect(message.title).toBe('Something went wrong');
        expect(JSON.stringify(message)).not.toContain('SQLSTATE');
        expect(describeError(new Error('Network Error')).title).toBe('Something went wrong');
    });

    it('is not fooled by a code that names a property of every object', () => {
        for (const code of ['constructor', '__proto__', 'toString', 'hasOwnProperty']) {
            expect(describeError(failure(500, { error: code })).title).toBe('Something went wrong');
        }
    });
});

describe('describeFailure', () => {
    it.each(['source_unavailable', 'file_not_found', 'not_server_pack', 'download_failed', 'download_too_large', 'upload_failed', 'extract_failed', 'sanitize_failed', 'disk_full'])('has words for %s', (code) => {
        const message = describeFailure(code);

        expect(message.title).not.toBe('The installation failed');
        expect(`${message.title} ${message.body}`).not.toContain(code);
    });

    it('answers an unknown code, an empty one, and a name of every object in general terms', () => {
        for (const code of ['something_new', '', 'constructor', '__proto__']) {
            expect(describeFailure(code).title).toBe('The installation failed');
        }
    });

    it('tells the person what to do when only the cleanup failed', () => {
        expect(describeFailure('sanitize_failed').body).toMatch(/start\.sh/);
    });
});

describe('server defaults', () => {
    const DEFAULTS = { default_source: 'curseforge', default_game_version: '1.20.1', default_loader: 'fabric' };

    it('reads them from this server, and reports what they are', async () => {
        const get = vi.spyOn(http, 'get').mockResolvedValue({ data: DEFAULTS } as never);

        await expect(getServerDefaults(UUID)).resolves.toEqual(DEFAULTS);
        expect(get).toHaveBeenCalledWith(`${BASE}/defaults`, { signal: undefined });
    });

    it('saves them to this server, with the body it was given', async () => {
        const put = vi.spyOn(http, 'put').mockResolvedValue({ data: DEFAULTS } as never);

        await expect(saveServerDefaults(UUID, DEFAULTS as never)).resolves.toEqual(DEFAULTS);
        expect(put).toHaveBeenCalledWith(`${BASE}/defaults`, DEFAULTS);
    });

    it('accepts an empty loader, and the four loaders', () => {
        expect(isServerDefaults({ ...DEFAULTS, default_loader: '' })).toBe(true);
        for (const loader of ['forge', 'fabric', 'quilt', 'neoforge']) {
            expect(isServerDefaults({ ...DEFAULTS, default_loader: loader })).toBe(true);
        }
    });

    it.each([
        ['an unknown source', { default_source: 'github' }],
        ['a loader the Panel does not know', { default_loader: 'bukkit' }],
        ['a loader that is not text', { default_loader: 3 }],
        ['a missing version', { default_game_version: undefined }],
    ])('refuses an answer with %s', (_label, over) => {
        expect(isServerDefaults({ ...DEFAULTS, ...over })).toBe(false);
    });

    it('refuses an answer of the wrong shape when reading or saving', async () => {
        vi.spyOn(http, 'get').mockResolvedValue({ data: { default_source: 'x' } } as never);
        vi.spyOn(http, 'put').mockResolvedValue({ data: 'text' } as never);

        await expect(getServerDefaults(UUID)).rejects.toThrow(/unexpected shape/);
        await expect(saveServerDefaults(UUID, DEFAULTS as never)).rejects.toThrow(/unexpected shape/);
    });
});

describe('a refused set of defaults (422)', () => {
    it('is explained in words, and not as a general failure', () => {
        const message = describeError(failure(422, { errors: { default_loader: ['The selected default loader is invalid.'] } }));

        expect(message.title).toBe('Those values cannot be saved');
        expect(JSON.stringify(message)).not.toContain('default_loader');
    });
});

