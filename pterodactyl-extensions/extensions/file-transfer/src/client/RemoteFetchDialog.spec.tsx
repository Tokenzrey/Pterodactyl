import { fireEvent, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { RemoteFetchDialog, stepText } from './RemoteFetchDialog';
import { fakeNetwork, renderInPanel, SERVER_UUID, usePanelHost, type FakeReply } from './test-utils';

// Starting a download on the Panel and following it: what may be sent, what is said while it runs, and how each failure reads.

usePanelHost();

const JOB = '99999999-8888-4777-8666-555555555555';
const FETCH = '/remote-fetch';
const PROGRESS = `/extension-progress/file-transfer/${JOB}`;

const progress = (status: 'running' | 'completed' | 'failed', percent: number, message = '') => ({
    data: { data: { id: JOB, extension: 'file-transfer', status, percent, message, sequence: percent, updated_at: '2026-01-01T00:00:00Z' } },
});

/** A network where starting works and the job reports these snapshots in turn (the last one repeats). */
function network(snapshots: ReturnType<typeof progress>[], start: FakeReply = { status: 202, data: { job_id: JOB } }) {
    let next = 0;

    return fakeNetwork((request) => {
        if (request.url.endsWith(FETCH)) {
            return start;
        }
        if (request.url.endsWith(PROGRESS)) {
            return snapshots[Math.min(next++, snapshots.length - 1)];
        }

        return { status: 404 };
    });
}

async function open(options: { directory?: string; onClose?: () => void; onFetched?: () => void } = {}) {
    await renderInPanel(<RemoteFetchDialog serverUuid={SERVER_UUID} directory={options.directory ?? '/plugins'} onClose={options.onClose ?? (() => {})} onFetched={options.onFetched ?? (() => {})} />, {
        permissions: ['file.create', 'ext.file-transfer.remote-fetch'],
    });

    return {
        type: (url: string) => fireEvent.change(screen.getByLabelText('Address'), { target: { value: url } }),
        name: (name: string) => fireEvent.change(screen.getByLabelText('Save as (optional)'), { target: { value: name } }),
        submit: () => fireEvent.click(screen.getByRole('button', { name: /^(fetch file|try again)$/i })),
    };
}

describe('before anything is sent', () => {
    it('cannot start without an address', async () => {
        network([]);
        await open();

        expect((screen.getByRole('button', { name: 'Fetch file' }) as HTMLButtonElement).disabled).toBe(true);
    });

    it.each(['example.com/a.zip', 'ftp://example.com/a', 'file:///etc/passwd', 'https://user:pw@example.com/a'])('refuses %j, and marks the field', async (value) => {
        const requests = network([]);
        const { type } = await open();

        type(value);

        expect((screen.getByRole('button', { name: 'Fetch file' }) as HTMLButtonElement).disabled).toBe(true);
        expect((screen.getByLabelText('Address') as HTMLInputElement).getAttribute('aria-invalid')).toBe('true');
        expect(requests).toHaveLength(0);
    });

    it('does not mark an empty field as wrong', async () => {
        network([]);
        await open();

        expect((screen.getByLabelText('Address') as HTMLInputElement).getAttribute('aria-invalid')).toBeNull();
    });

    it('refuses a name the backend would, and marks the field', async () => {
        network([]);
        const { type, name } = await open();
        type('https://example.com/a.zip');

        name('a/b');

        expect((screen.getByRole('button', { name: 'Fetch file' }) as HTMLButtonElement).disabled).toBe(true);
        expect((screen.getByLabelText('Save as (optional)') as HTMLInputElement).getAttribute('aria-invalid')).toBe('true');
    });

    it('says which folder the file will go to', async () => {
        network([]);
        await open({ directory: '/plugins/Essentials' });

        expect(screen.getByText(/saves it in \/plugins\/Essentials on this server/)).toBeTruthy();
    });
});

describe('starting', () => {
    it('sends the address and folder, and leaves the name out when none was typed', async () => {
        const requests = network([progress('running', 10)]);
        const { type, submit } = await open({ directory: '/plugins' });
        type('  https://example.com/a.zip  ');

        submit();

        await screen.findByRole('progressbar', { name: 'Download progress' });
        expect(requests[0].url).toContain(`/api/client/servers/${SERVER_UUID}/extensions/file-transfer/remote-fetch`);
        expect(requests[0].body).toEqual({ url: 'https://example.com/a.zip', target_directory: 'plugins' });
    });

    it('sends the name when one was typed, and "." for the root folder', async () => {
        const requests = network([progress('running', 10)]);
        const { type, name, submit } = await open({ directory: '/' });
        type('https://example.com/download?id=7');
        name('world.zip');

        submit();

        await screen.findByRole('progressbar');
        expect(requests[0].body).toEqual({ url: 'https://example.com/download?id=7', target_directory: '.', filename: 'world.zip' });
    });

    it.each([
        [422, 'invalid_url', 'That address cannot be fetched'],
        [403, undefined, 'Not allowed'],
        [429, undefined, 'Too many requests'],
        [500, undefined, 'Something went wrong'],
    ])('explains a %i %s refusal and keeps the form', async (status, code, title) => {
        network([], { status, data: code ? { error: code } : {} });
        const { type, submit } = await open();
        type('https://example.com/a.zip');

        submit();

        const alert = await screen.findByRole('alert');
        expect(alert.textContent).toContain(title);
        expect((screen.getByLabelText('Address') as HTMLInputElement).value).toBe('https://example.com/a.zip');
        expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();
    });

    it('treats an answer without a job id as a failure instead of waiting for nothing', async () => {
        network([], { status: 202, data: {} });
        const { type, submit } = await open();
        type('https://example.com/a.zip');

        submit();

        expect((await screen.findByRole('alert')).textContent).toContain('Something went wrong');
        expect(screen.queryByRole('progressbar')).toBeNull();
    });
});

describe('following the download', () => {
    it('says it is downloading, and that the window may be closed', async () => {
        network([progress('running', 35)]);
        const { type, submit } = await open();
        type('https://example.com/a.zip');

        submit();

        expect(await screen.findByText('Downloading from the address…')).toBeTruthy();
        expect(screen.getByText(/you can close this window/i)).toBeTruthy();
    });

    it('says the file is being handed to the server from 80 percent on', async () => {
        network([progress('running', 80)]);
        const { type, submit } = await open();
        type('https://example.com/a.zip');

        submit();

        expect(await screen.findByText('Handing the file to the server…')).toBeTruthy();
    });

    it('says the file is on the server when done, and refreshes the list once', async () => {
        network([progress('running', 40), progress('completed', 100, 'File transferred successfully.')]);
        const onFetched = vi.fn();
        const { type, submit } = await open({ onFetched });
        type('https://example.com/a.zip');

        submit();

        expect(await screen.findByText('The file is on the server', {}, { timeout: 5000 })).toBeTruthy();
        expect(onFetched).toHaveBeenCalledTimes(1);
        expect(screen.getByRole('button', { name: 'Done' })).toBeTruthy();
    });

    it.each([
        ['download_too_large', 'The file is too big'],
        ['timeout', 'The download took too long'],
        ['connection_refused', 'The other server could not be reached'],
        ['invalid_url', 'That address cannot be fetched'],
        ['upload_failed', 'The server did not accept the file'],
        ['download_failed', 'The download failed'],
    ])('says in words what the failure code %s means', async (code, title) => {
        network([progress('failed', 30, code)]);
        const onFetched = vi.fn();
        const { type, submit } = await open({ onFetched });
        type('https://example.com/a.zip');

        submit();

        const alert = await screen.findByRole('alert');
        expect(alert.textContent).toContain(title);
        expect(alert.textContent).not.toContain(code === 'download_failed' ? '\u0000' : code);
        expect(onFetched).not.toHaveBeenCalled();
    });

    it('goes back to the form to try again, and asks the Panel for a new download', async () => {
        const requests = network([progress('failed', 30, 'timeout')]);
        const { type, submit } = await open();
        type('https://example.com/a.zip');
        submit();
        await screen.findByRole('alert');

        fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

        expect((screen.getByLabelText('Address') as HTMLInputElement).value).toBe('https://example.com/a.zip');
        submit();
        await screen.findByRole('alert');
        expect(requests.filter((request) => request.url.endsWith(FETCH))).toHaveLength(2);
    });

    it('says it lost track when the Panel no longer reports on the job', async () => {
        fakeNetwork((request) => (request.url.endsWith(FETCH) ? { status: 202, data: { job_id: JOB } } : { status: 404, data: {} }));
        const { type, submit } = await open();
        type('https://example.com/a.zip');

        submit();

        expect(await screen.findByText('Lost track of the download')).toBeTruthy();
        expect(screen.getByRole('button', { name: 'Fetch again' })).toBeTruthy();
    });
});

describe('stepText', () => {
    it.each([
        [0, 'Downloading from the address…'],
        [79, 'Downloading from the address…'],
        [80, 'Handing the file to the server…'],
        [99, 'Handing the file to the server…'],
    ])('at %i percent says %s', (percent, expected) => {
        expect(stepText(percent)).toBe(expected);
    });
});
