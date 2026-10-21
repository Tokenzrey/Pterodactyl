import { act, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import ModpackScreen from './ModpackScreen';
import { fakeNetwork, renderInPanel, SERVER_UUID, usePanelHost, type FakeReply } from './test-utils';

// AC-MI17, AC-MI18: search with a pause, results, an install that is confirmed, and its progress.

usePanelHost();
afterEach(() => vi.useRealTimers());

const JOB = '99999999-8888-4777-8666-555555555555';
const PROGRESS = `/extension-progress/modpack-installer/${JOB}`;

const file = (over: Record<string, unknown> = {}) => ({ file_id: '4002', name: 'atm9-1.0.0.zip', game_version: '1.20.1', loader: 'forge', is_server_pack: true, file_size_mb: 100, ...over });
const pack = (over: Record<string, unknown> = {}) => ({ source: 'curseforge', project_id: '123', name: 'All the Mods 9', summary: 'Everything.', downloads: 5000, icon_url: null, latest_files: [file()], ...over });
const found = (results: unknown[], total = results.length, page = 0) => ({ data: { results, total, page } });
const running = (percent: number) => ({ data: { data: { id: JOB, extension: 'modpack-installer', status: 'running', percent, message: '', sequence: percent, updated_at: '2026-01-01T00:00:00Z' } } });
const completed = { data: { data: { id: JOB, extension: 'modpack-installer', status: 'completed', percent: 100, message: 'ok', sequence: 100, updated_at: '2026-01-01T00:00:00Z' } } };

const SAVED = { default_source: 'curseforge', default_game_version: '', default_loader: '' };

/**
 * Opens the screen. The saved defaults are answered by `defaults`; the other requests by `answer`. Then lets timers move
 * on their own while 500 ms can still be crossed at once.
 */
async function open(
    answer: (request: Parameters<Parameters<typeof fakeNetwork>[0]>[0]) => FakeReply | Promise<FakeReply>,
    defaults: FakeReply = { data: SAVED },
) {
    const requests = fakeNetwork((request) => (request.url.endsWith('/defaults') && request.method === 'get' ? defaults : answer(request)));
    await renderInPanel(<ModpackScreen />, { owner: true });
    await screen.findByRole('search');
    vi.useFakeTimers({ shouldAdvanceTime: true });

    return {
        requests,
        search: async (text: string) => {
            fireEvent.change(screen.getByLabelText('Search modpacks'), { target: { value: text } });
            await act(async () => void vi.advanceTimersByTime(500));
        },
    };
}

type Recorded = ReturnType<typeof fakeNetwork>[number];
const searches = (requests: Recorded[]) => requests.filter((request) => request.url.endsWith('/search'));

describe('before a search', () => {
    it('invites one, and asks the Panel for nothing', async () => {
        const { requests } = await open(() => found([]));

        expect(screen.getByText('Search for a modpack')).toBeTruthy();
        expect(searches(requests)).toHaveLength(0);
    });

    it('does not search for a blank query', async () => {
        const { requests, search } = await open(() => found([]));

        await search('   ');

        expect(searches(requests)).toHaveLength(0);
    });
});

describe('searching', () => {
    it('asks the Panel after the pause, on this server, with the criteria and the first page', async () => {
        const { requests, search } = await open(() => found([pack()]));

        await search('atm');

        expect(await screen.findByRole('heading', { name: 'All the Mods 9' })).toBeTruthy();
        expect(searches(requests)).toHaveLength(1);
        expect(searches(requests)[0].url).toBe(`/api/client/servers/${SERVER_UUID}/extensions/modpack-installer/search`);
        expect(searches(requests)[0].params).toEqual({ source: 'curseforge', query: 'atm', page: 0 });
    });

    it('shows that it is searching', async () => {
        const { search } = await open(() => new Promise<FakeReply>(() => {}));

        await search('atm');

        expect(await screen.findByText('Searching…')).toBeTruthy();
    });

    it('cancels the search it replaces when the criteria change (FR-MI15)', async () => {
        const { requests, search } = await open((request) => (searches([request]).length > 0 && (request.params.query === 'at') ? new Promise<FakeReply>(() => {}) : found([pack({ name: 'Second' })])));

        await search('at');
        await waitFor(() => expect(searches(requests)).toHaveLength(1));
        const first = searches(requests)[0];
        await search('atm');

        expect(await screen.findByRole('heading', { name: 'Second' })).toBeTruthy();
        expect(first.signal?.aborted).toBe(true);
    });

    it('says nothing was found, and what to try', async () => {
        const { search } = await open(() => found([]));

        await search('zzz');

        expect(await screen.findByText('No modpacks found')).toBeTruthy();
        expect(screen.getByText(/take away the version or loader/)).toBeTruthy();
    });

    it('goes back to the invitation when the query is cleared', async () => {
        const { search } = await open(() => found([pack()]));
        await search('atm');
        await screen.findByRole('heading', { name: 'All the Mods 9' });

        await search('');

        expect(await screen.findByText('Search for a modpack')).toBeTruthy();
        expect(screen.queryByRole('heading', { name: 'All the Mods 9' })).toBeNull();
    });
});

describe('when the search fails', () => {
    it.each([
        [503, 'curseforge_not_configured', 'CurseForge is not set up'],
        [503, 'source_unavailable', 'The modpack source is not answering'],
        [403, undefined, 'Not allowed'],
        [429, undefined, 'Too many requests'],
        [500, undefined, 'Something went wrong'],
    ])('says in words what a %i %s means', async (status, code, title) => {
        const { search } = await open(() => ({ status, data: code ? { error: code } : {} }));

        await search('atm');

        const alert = await screen.findByRole('alert');
        expect(alert.textContent).toContain(title);
        expect(alert.textContent).not.toContain(code ?? '\u0000');
    });

    it('offers to try again, and shows the result when it works', async () => {
        let fail = true;
        const { search } = await open(() => (fail ? { status: 503, data: { error: 'source_unavailable' } } : found([pack()])));
        await search('atm');
        await screen.findByRole('alert');

        fail = false;
        fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

        expect(await screen.findByRole('heading', { name: 'All the Mods 9' })).toBeTruthy();
        expect(screen.queryByRole('alert')).toBeNull();
    });
});

describe('Modrinth', () => {
    it('says its packs cannot be installed here, and why', async () => {
        const { search } = await open(() => found([pack({ source: 'modrinth', project_id: 'AANobbMI', latest_files: [] })]));
        fireEvent.change(screen.getByLabelText('Source'), { target: { value: 'modrinth' } });

        await search('fabulous');

        expect(await screen.findByText('Modrinth packs cannot be installed here')).toBeTruthy();
        expect(screen.getByText(/only packs for players/)).toBeTruthy();
        expect(screen.queryByRole('button', { name: /Install/ })).toBeNull();
    });

    it('does not say so for CurseForge', async () => {
        const { search } = await open(() => found([pack()]));

        await search('atm');
        await screen.findByRole('heading', { name: 'All the Mods 9' });

        expect(screen.queryByText('Modrinth packs cannot be installed here')).toBeNull();
    });
});

describe('pages', () => {
    it('has none to turn when everything fits on one', async () => {
        const { search } = await open(() => found([pack()], 20));

        await search('atm');
        await screen.findByRole('heading', { name: 'All the Mods 9' });

        expect(screen.queryByRole('navigation', { name: 'Pages' })).toBeNull();
    });

    it('turns to the next page and back, asking for each', async () => {
        const { requests, search } = await open((request) => found([pack({ name: `Page ${Number(request.params.page) + 1}` })], 45, Number(request.params.page)));
        await search('atm');
        await screen.findByRole('heading', { name: 'Page 1' });
        const nav = screen.getByRole('navigation', { name: 'Pages' });
        expect(within(nav).getByText('Page 1 of 3')).toBeTruthy();
        expect((within(nav).getByRole('button', { name: 'Previous' }) as HTMLButtonElement).disabled).toBe(true);

        fireEvent.click(within(nav).getByRole('button', { name: 'Next' }));
        await screen.findByRole('heading', { name: 'Page 2' });
        fireEvent.click(within(nav).getByRole('button', { name: 'Previous' }));
        await screen.findByRole('heading', { name: 'Page 1' });

        // Going back to a page that was just read is answered from the cache, not asked again.
        expect(searches(requests).map((request) => request.params.page)).toEqual([0, 1]);
    });

    it('stops at the last page', async () => {
        const { search } = await open((request) => found([pack({ name: `Page ${Number(request.params.page) + 1}` })], 45, Number(request.params.page)));
        await search('atm');
        await screen.findByRole('heading', { name: 'Page 1' });
        const nav = screen.getByRole('navigation', { name: 'Pages' });

        fireEvent.click(within(nav).getByRole('button', { name: 'Next' }));
        await screen.findByRole('heading', { name: 'Page 2' });
        fireEvent.click(within(nav).getByRole('button', { name: 'Next' }));
        await screen.findByRole('heading', { name: 'Page 3' });

        expect((within(nav).getByRole('button', { name: 'Next' }) as HTMLButtonElement).disabled).toBe(true);
    });

    it('starts again at the first page when the criteria change', async () => {
        const { requests, search } = await open((request) => found([pack({ name: `Page ${Number(request.params.page) + 1}` })], 45, Number(request.params.page)));
        await search('atm');
        await screen.findByRole('heading', { name: 'Page 1' });
        fireEvent.click(within(screen.getByRole('navigation', { name: 'Pages' })).getByRole('button', { name: 'Next' }));
        await screen.findByRole('heading', { name: 'Page 2' });

        await search('atm2');
        await waitFor(() => expect(searches(requests).at(-1)?.params).toEqual({ source: 'curseforge', query: 'atm2', page: 0 }));
    });
});

describe('installing', () => {
    function installFlow(progress: Array<unknown> = [running(10), completed]) {
        let next = 0;

        return (request: { url: string; method: string }): FakeReply => {
            if (request.url.endsWith('/search')) {
                return found([pack()]);
            }
            if (request.url.endsWith('/install')) {
                return { status: 202, data: { job_id: JOB } };
            }
            if (request.url.endsWith(PROGRESS)) {
                return progress[Math.min(next++, progress.length - 1)] as FakeReply;
            }

            return { status: 404 };
        };
    }

    it('asks first, then installs and follows the progress to the end, and goes back to the search', async () => {
        const { requests, search } = await open(installFlow());
        await search('atm');
        fireEvent.click(await screen.findByRole('button', { name: /Install the server pack of atm9-1.0.0.zip/ }));
        expect(await screen.findByRole('dialog', { name: 'Install All the Mods 9?' })).toBeTruthy();

        fireEvent.change(screen.getByLabelText('Install into folder (optional)'), { target: { value: 'packs/atm9' } });
        fireEvent.click(screen.getByRole('button', { name: 'Install' }));

        expect(await screen.findByRole('heading', { name: 'Installing All the Mods 9' })).toBeTruthy();
        expect(requests.find((request) => request.url.endsWith('/install'))?.body).toEqual({ source: 'curseforge', project_id: '123', file_id: '4002', target_directory: 'packs/atm9' });
        expect(await screen.findByText('All the Mods 9 is installed', {}, { timeout: 8000 })).toBeTruthy();

        fireEvent.click(screen.getByRole('button', { name: 'Install another' }));
        expect(await screen.findByRole('search')).toBeTruthy();
    }, 15000);

    it('installs nothing when the dialog is cancelled', async () => {
        const { requests, search } = await open(installFlow());
        await search('atm');
        fireEvent.click(await screen.findByRole('button', { name: /Install the server pack/ }));
        await screen.findByRole('dialog');

        fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

        await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
        expect(requests.some((request) => request.url.endsWith('/install'))).toBe(false);
    });

    it('keeps the results when the Panel refuses, and says why', async () => {
        const answer = installFlow();
        const { search } = await open((request) => (request.url.endsWith('/install') ? { status: 409, data: { error: 'install_in_progress' } } : answer(request)));
        await search('atm');
        fireEvent.click(await screen.findByRole('button', { name: /Install the server pack/ }));
        await screen.findByRole('dialog');

        fireEvent.click(screen.getByRole('button', { name: 'Install' }));

        expect((await screen.findByRole('alert')).textContent).toContain('This pack is already being installed');
        // The dialog is modal, so the results behind it are hidden from assistive technology but still there.
        expect(screen.getByRole('heading', { name: 'All the Mods 9', hidden: true })).toBeTruthy();
    });
});

describe('the server defaults', () => {
    it('opens the form with the defaults the server saved', async () => {
        await open(() => found([]), { data: { default_source: 'curseforge', default_game_version: '1.20.1', default_loader: 'fabric' } });

        expect((screen.getByLabelText('Minecraft version') as HTMLInputElement).value).toBe('1.20.1');
        expect((screen.getByLabelText('Mod loader') as HTMLSelectElement).value).toBe('fabric');
    });

    it('opens with the built-in defaults when they cannot be read', async () => {
        await open(() => found([]), { status: 500, data: {} });

        expect((screen.getByLabelText('Minecraft version') as HTMLInputElement).value).toBe('');
        expect((screen.getByLabelText('Mod loader') as HTMLSelectElement).value).toBe('');
    });

    it('saves what is on the form as the defaults, and says so', async () => {
        const { requests } = await open((request) => (request.url.endsWith('/defaults') ? { data: { default_source: 'curseforge', default_game_version: '1.21', default_loader: 'quilt' } } : found([])));

        fireEvent.change(screen.getByLabelText('Minecraft version'), { target: { value: '1.21' } });
        fireEvent.change(screen.getByLabelText('Mod loader'), { target: { value: 'quilt' } });
        fireEvent.click(screen.getByRole('button', { name: /Save these as the defaults/ }));

        expect(await screen.findByText("Saved as this server's defaults")).toBeTruthy();
        const saved = requests.find((request) => request.method === 'put');
        expect(saved?.url.endsWith('/defaults')).toBe(true);
        expect(saved?.body).toEqual({ default_source: 'curseforge', default_game_version: '1.21', default_loader: 'quilt' });
    });

    it('says in words why the Panel refused the defaults, and does not claim they were saved', async () => {
        await open((request) => (request.url.endsWith('/defaults') ? { status: 422, data: {} } : found([])));

        fireEvent.change(screen.getByLabelText('Minecraft version'), { target: { value: '1.21' } });
        fireEvent.click(screen.getByRole('button', { name: /Save these as the defaults/ }));

        expect((await screen.findByRole('alert')).textContent).toContain('Those values cannot be saved');
        expect(screen.queryByText("Saved as this server's defaults")).toBeNull();
    });
});

