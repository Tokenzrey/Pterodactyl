import { fireEvent, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ChunkedUploader, progressText } from './ChunkedUploader';
import { fakeNetwork, renderInPanel, usePanelHost, type FakeReply } from './test-utils';

// The screen around the upload engine: what is enabled when, what is said while it runs, and what is said when it fails.

usePanelHost();

const CHUNK = '/extensions/file-transfer/chunk';
const config = { chunkSizeMb: 1, maxFileMb: 2 };

function file(content: string | Uint8Array, name = 'world.zip') {
    return new File([content as BlobPart], name);
}

async function open(options: { onClose?: () => void; onUploaded?: () => void; directory?: string } = {}) {
    const view = await renderInPanel(<ChunkedUploader serverUuid="11111111-2222-4333-8444-555555555555" directory={options.directory ?? '/plugins'} config={config} onClose={options.onClose ?? (() => {})} onUploaded={options.onUploaded ?? (() => {})} />, {
        permissions: ['file.create'],
    });

    return {
        unmount: view.unmount,
        pick: (picked: File) => fireEvent.change(screen.getByLabelText('File'), { target: { files: [picked] } }),
        upload: () => fireEvent.click(screen.getByRole('button', { name: /^(upload|try again)$/i })),
    };
}

afterEach(() => vi.restoreAllMocks());

describe('before anything is sent', () => {
    it('cannot upload until a file is chosen', async () => {
        fakeNetwork(() => ({}));
        await open();

        expect((screen.getByRole('button', { name: 'Upload' }) as HTMLButtonElement).disabled).toBe(true);
    });

    it('fills in a name the backend will take, from the file chosen', async () => {
        fakeNetwork(() => ({}));
        const { pick } = await open();

        pick(file('x', 'My World (1).zip'));

        expect((screen.getByLabelText('Save as') as HTMLInputElement).value).toBe('My_World__1_.zip');
        expect((screen.getByRole('button', { name: 'Upload' }) as HTMLButtonElement).disabled).toBe(false);
    });

    it('says what the limit is, and that an existing file is replaced', async () => {
        fakeNetwork(() => ({}));
        await open();

        expect(screen.getByText('Up to 2 MB.')).toBeTruthy();
        expect(screen.getByText(/existing file with this name is replaced/i)).toBeTruthy();
    });

    it('refuses a file over the limit, says why, and keeps Upload off', async () => {
        const requests = fakeNetwork(() => ({}));
        const { pick } = await open();

        pick(file(new Uint8Array(2 * 1024 * 1024 + 1)));

        expect(screen.getByRole('alert').textContent).toMatch(/this file is 2 MB\. the limit is 2 MB/i);
        expect((screen.getByLabelText('File') as HTMLInputElement).getAttribute('aria-invalid')).toBe('true');
        expect((screen.getByRole('button', { name: 'Upload' }) as HTMLButtonElement).disabled).toBe(true);
        expect(requests).toHaveLength(0);
    });

    it('accepts a file of exactly the limit', async () => {
        fakeNetwork(() => ({}));
        const { pick } = await open();

        pick(file(new Uint8Array(2 * 1024 * 1024)));

        expect((screen.getByRole('button', { name: 'Upload' }) as HTMLButtonElement).disabled).toBe(false);
    });

    it.each(['', '..', 'a/b', 'a b', 'ü'])('keeps Upload off for the name %j and marks the field', async (name) => {
        fakeNetwork(() => ({}));
        const { pick } = await open();
        pick(file('x'));

        fireEvent.change(screen.getByLabelText('Save as'), { target: { value: name } });

        expect((screen.getByRole('button', { name: 'Upload' }) as HTMLButtonElement).disabled).toBe(true);
        expect((screen.getByLabelText('Save as') as HTMLInputElement).getAttribute('aria-invalid')).toBe(name === '' ? null : 'true');
    });
});

describe('sending', () => {
    it('sends the file to the folder shown, then says it is on the server and refreshes the list', async () => {
        const requests = fakeNetwork((request) => (request.url.endsWith('/merge') ? { data: { uploaded: true } } : { data: { accepted: 0, remaining: 0 } }));
        const onUploaded = vi.fn();
        const { pick, upload } = await open({ onUploaded, directory: '/plugins/Essentials' });
        pick(file('hello', 'a.txt'));

        upload();

        expect(await screen.findByText('a.txt is on the server')).toBeTruthy();
        expect(screen.getByText('It is in /plugins/Essentials.')).toBeTruthy();
        expect(onUploaded).toHaveBeenCalledTimes(1);
        expect(requests.map((request) => request.url)).toEqual([expect.stringContaining(CHUNK), expect.stringContaining(`${CHUNK}/merge`)]);
        expect(requests[1].body).toMatchObject({ filename: 'a.txt', target_directory: 'plugins/Essentials' });
    });

    it('sends a file in the root folder as "."', async () => {
        const requests = fakeNetwork((request) => (request.url.endsWith('/merge') ? { data: { uploaded: true } } : { data: { accepted: 0, remaining: 0 } }));
        const { pick, upload } = await open({ directory: '/' });
        pick(file('x', 'a.txt'));

        upload();

        await screen.findByText('a.txt is on the server');
        expect(requests[1].body).toMatchObject({ target_directory: '.' });
    });

    it('shows a progress bar and a status line while it runs, and a way to cancel', async () => {
        let release: (reply: FakeReply) => void = () => {};
        fakeNetwork(() => new Promise<FakeReply>((resolve) => (release = resolve)));
        const { pick, upload } = await open();
        pick(file('hello'));

        upload();

        expect(await screen.findByRole('progressbar', { name: 'Uploading world.zip' })).toBeTruthy();
        expect(screen.getByRole('status').textContent).toBe('Starting…');
        expect(screen.getByText(/keep this page open/i)).toBeTruthy();
        expect(screen.getByRole('button', { name: 'Cancel upload' })).toBeTruthy();

        release({ data: { accepted: 0, remaining: 0 } });
    });

    it('stops when cancelled, sends no merge, and returns to the choice with the file still chosen', async () => {
        const requests = fakeNetwork(() => new Promise<FakeReply>(() => {}));
        const { pick, upload } = await open();
        pick(file('hello'));
        upload();
        await screen.findByRole('button', { name: 'Cancel upload' });

        fireEvent.click(screen.getByRole('button', { name: 'Cancel upload' }));

        expect(await screen.findByRole('button', { name: 'Upload' })).toBeTruthy();
        expect(requests.some((request) => request.url.endsWith('/merge'))).toBe(false);
        expect(screen.queryByText(/is on the server/)).toBeNull();
    });

    it('does not show the cancel as a failure', async () => {
        fakeNetwork(() => new Promise<FakeReply>(() => {}));
        const { pick, upload } = await open();
        pick(file('hello'));
        upload();

        fireEvent.click(await screen.findByRole('button', { name: 'Cancel upload' }));

        await screen.findByRole('button', { name: 'Upload' });
        expect(screen.queryByRole('alert')).toBeNull();
    });

    it('aborts the request in flight when the dialog goes away, so nothing keeps running behind it', async () => {
        const requests = fakeNetwork(() => new Promise<FakeReply>(() => {}));
        const { pick, upload, unmount } = await open();
        pick(file('hello'));
        upload();
        // The piece is read before it is sent, so the request appears a moment after the dialog switches to "sending".
        await waitFor(() => expect(requests).toHaveLength(1));
        expect(requests[0].signal?.aborted).toBe(false);

        unmount();

        expect(requests[0].signal?.aborted).toBe(true);
    });
});

describe('when it fails', () => {
    it.each([
        [422, 'checksum_mismatch', 'The file arrived damaged'],
        [422, 'invalid_filename', 'That file name cannot be used'],
        [413, 'file_too_large', 'The file is too large'],
        [503, 'upload_failed', 'The server did not accept the file'],
        [403, undefined, 'Not allowed'],
    ])('says in words what a %i %s means, and offers another try', async (status, code, title) => {
        fakeNetwork((request) => (request.url.endsWith('/merge') ? { status, data: code ? { error: code } : {} } : { data: { accepted: 0, remaining: 0 } }));
        const { pick, upload } = await open();
        pick(file('hello'));

        upload();

        const alert = await screen.findByRole('alert');
        expect(alert.textContent).toContain(title);
        expect(alert.textContent).not.toContain(code ?? '\u0000');
        expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();
        expect((screen.getByLabelText('Save as') as HTMLInputElement).value).toBe('world.zip');
    });

    it('does not claim success or refresh the list when the merge failed', async () => {
        fakeNetwork((request) => (request.url.endsWith('/merge') ? { status: 422, data: { error: 'chunks_missing' } } : { data: { accepted: 0, remaining: 0 } }));
        const onUploaded = vi.fn();
        const { pick, upload } = await open({ onUploaded });
        pick(file('hello'));

        upload();

        await screen.findByRole('alert');
        expect(onUploaded).not.toHaveBeenCalled();
        expect(screen.queryByText(/is on the server/)).toBeNull();
    });

    it('starts over under a new upload id when tried again', async () => {
        let fail = true;
        const requests = fakeNetwork((request) => {
            if (request.url.endsWith('/merge')) {
                return fail ? { status: 422, data: { error: 'checksum_mismatch' } } : { data: { uploaded: true } };
            }

            return { data: { accepted: 0, remaining: 0 } };
        });
        const { pick, upload } = await open();
        pick(file('hello'));
        upload();
        await screen.findByRole('alert');

        fail = false;
        upload();

        await screen.findByText('world.zip is on the server');
        const ids = requests.map((request) => (request.body as { upload_id: string }).upload_id);
        expect(new Set(ids).size).toBe(2);
        await waitFor(() => expect(requests).toHaveLength(4));
    });
});

describe('progressText', () => {
    it('says it is starting before anything is known', () => {
        expect(progressText(null)).toBe('Starting…');
    });

    it('says how much has gone and which piece', () => {
        expect(progressText({ sent: 5 * 1024 * 1024, total: 20 * 1024 * 1024, chunk: 1, chunks: 4, phase: 'uploading' })).toBe('Sent 5 MB of 20 MB (piece 1 of 4)');
    });

    it('says what the last step is', () => {
        expect(progressText({ sent: 10, total: 10, chunk: 1, chunks: 1, phase: 'finishing' })).toMatch(/^Finishing/);
    });
});
