import { fireEvent, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { ModpackFile, ModpackResult } from './api';
import { InstallDialog } from './InstallDialog';
import { fakeNetwork, renderInPanel, SERVER_UUID, usePanelHost } from './test-utils';

usePanelHost();

const JOB = '99999999-8888-4777-8666-555555555555';
const file: ModpackFile = { file_id: '4002', name: 'atm9-server.zip', game_version: '1.20.1', loader: 'forge', is_server_pack: true, file_size_mb: 100 };
const pack: ModpackResult = { source: 'curseforge', project_id: '123', name: 'All the Mods 9', summary: '', downloads: 1, icon_url: null, latest_files: [file] };

async function open(handlers: { onClose?: () => void; onStarted?: (id: string) => void } = {}) {
    await renderInPanel(<InstallDialog serverUuid={SERVER_UUID} result={pack} file={file} onClose={handlers.onClose ?? (() => {})} onStarted={handlers.onStarted ?? (() => {})} />, { owner: true });

    return {
        folder: (value: string) => fireEvent.change(screen.getByLabelText('Install into folder (optional)'), { target: { value } }),
        install: () => fireEvent.click(screen.getByRole('button', { name: /^(install|try again)$/i })),
    };
}

describe('before anything is sent', () => {
    it('asks which pack and which file, and says what it does to the server', async () => {
        fakeNetwork(() => ({}));
        await open();

        expect(screen.getByRole('dialog', { name: 'Install All the Mods 9?' })).toBeTruthy();
        expect(screen.getByText(/atm9-server\.zip is downloaded by the Panel/)).toBeTruthy();
        expect(screen.getByText(/replace files with the same name/)).toBeTruthy();
    });

    it.each(['/etc', '..', 'a/../b', 'a//b', 'my packs', 'café'])('refuses the folder %j: says why, marks the field, and keeps Install off', async (value) => {
        const requests = fakeNetwork(() => ({}));
        const { folder } = await open();

        folder(value);

        expect((screen.getByRole('button', { name: 'Install' }) as HTMLButtonElement).disabled).toBe(true);
        expect(screen.getByLabelText('Install into folder (optional)').getAttribute('aria-invalid')).toBe('true');
        expect(requests).toHaveLength(0);
    });

    it('sends nothing when the form is submitted with a folder that is refused, whatever the button says', async () => {
        const requests = fakeNetwork(() => ({ status: 202, data: { job_id: JOB } }));
        const { folder } = await open();

        folder('../etc');
        fireEvent.submit(screen.getByLabelText('Install into folder (optional)').closest('form') as HTMLFormElement);

        await new Promise((resolve) => setTimeout(resolve, 50));
        expect(requests).toHaveLength(0);
    });

    it('can be installed with no folder at all', async () => {
        fakeNetwork(() => ({}));
        await open();

        expect((screen.getByRole('button', { name: 'Install' }) as HTMLButtonElement).disabled).toBe(false);
    });

    it('closes without sending anything when cancelled', async () => {
        const requests = fakeNetwork(() => ({}));
        const onClose = vi.fn();
        await open({ onClose });

        fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

        expect(onClose).toHaveBeenCalledTimes(1);
        expect(requests).toHaveLength(0);
    });
});

describe('installing', () => {
    it('sends the ids and nothing else, and no folder when none was typed (T-MI1)', async () => {
        const requests = fakeNetwork(() => ({ status: 202, data: { job_id: JOB } }));
        const { install } = await open();

        install();

        await waitFor(() => expect(requests).toHaveLength(1));
        expect(requests[0].url).toBe(`/api/client/servers/${SERVER_UUID}/extensions/modpack-installer/install`);
        expect(requests[0].body).toEqual({ source: 'curseforge', project_id: '123', file_id: '4002' });
    });

    it('sends the folder that was typed', async () => {
        const requests = fakeNetwork(() => ({ status: 202, data: { job_id: JOB } }));
        const { folder, install } = await open();

        folder('packs/atm9');
        install();

        await waitFor(() => expect(requests).toHaveLength(1));
        expect(requests[0].body).toEqual({ source: 'curseforge', project_id: '123', file_id: '4002', target_directory: 'packs/atm9' });
    });

    it('hands on the id of the record to follow', async () => {
        fakeNetwork(() => ({ status: 202, data: { job_id: JOB } }));
        const onStarted = vi.fn();
        const { install } = await open({ onStarted });

        install();

        await waitFor(() => expect(onStarted).toHaveBeenCalledWith(JOB));
    });

    it('does not send twice when pressed twice', async () => {
        const requests = fakeNetwork(() => ({ status: 202, data: { job_id: JOB } }));
        const { install } = await open();

        install();
        install();

        await waitFor(() => expect(requests.length).toBeGreaterThan(0));
        expect(requests).toHaveLength(1);
    });
});

describe('when the Panel says no', () => {
    it.each([
        [409, 'install_in_progress', 'This pack is already being installed'],
        [422, 'not_server_pack', 'This is not a server pack'],
        [422, 'download_not_allowed', 'The author does not allow this download'],
        [422, 'download_too_large', 'That pack is too large'],
        [503, 'curseforge_not_configured', 'CurseForge is not set up'],
        [503, 'source_unavailable', 'The modpack source is not answering'],
        [404, 'file_not_found', 'That file is gone'],
    ])('says in words what a %i %s means, keeps the dialog, and offers another try', async (status, code, title) => {
        fakeNetwork(() => ({ status, data: { error: code } }));
        const onStarted = vi.fn();
        const { install } = await open({ onStarted });

        install();

        const alert = await screen.findByRole('alert');
        expect(alert.textContent).toContain(title);
        expect(alert.textContent).not.toContain(code);
        expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();
        expect(onStarted).not.toHaveBeenCalled();
    });

    it('says something went wrong for an error it has no words for, and shows nothing the server said', async () => {
        fakeNetwork(() => ({ status: 500, data: { error: 'boom', message: 'SQLSTATE[HY000] /var/www' } }));
        const { install } = await open();

        install();

        const alert = await screen.findByRole('alert');
        expect(alert.textContent).toContain('Something went wrong');
        expect(alert.textContent).not.toContain('SQLSTATE');
    });

    it('keeps the folder that was typed, so that a retry does not start over', async () => {
        fakeNetwork(() => ({ status: 503, data: { error: 'source_unavailable' } }));
        const { folder, install } = await open();
        folder('packs');

        install();
        await screen.findByRole('alert');

        expect((screen.getByLabelText('Install into folder (optional)') as HTMLInputElement).value).toBe('packs');
    });
});
