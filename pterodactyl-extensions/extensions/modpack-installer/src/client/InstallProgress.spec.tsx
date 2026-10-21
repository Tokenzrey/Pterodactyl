import { fireEvent, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { InstallProgress, stepText } from './InstallProgress';
import { fakeNetwork, renderInPanel, SERVER_UUID, usePanelHost } from './test-utils';

// FR-MI14, AC-MI18: the record of the install is followed on the Panel's own progress route, and every ending is in words.

usePanelHost();

const JOB = '99999999-8888-4777-8666-555555555555';
const PROGRESS = `/extension-progress/modpack-installer/${JOB}`;

const record = (status: 'running' | 'completed' | 'failed', percent: number, message = '') => ({
    data: { data: { id: JOB, extension: 'modpack-installer', status, percent, message, sequence: percent, updated_at: '2026-01-01T00:00:00Z' } },
});

async function follow(answers: Array<ReturnType<typeof record> | { status: number }>) {
    let next = 0;
    const requests = fakeNetwork((request) => {
        if (request.url.endsWith(PROGRESS)) {
            return answers[Math.min(next++, answers.length - 1)];
        }

        return { status: 404 };
    });
    const onDone = vi.fn();
    await renderInPanel(<InstallProgress jobId={JOB} serverUuid={SERVER_UUID} name="All the Mods 9" onDone={onDone} />, { owner: true });

    return { requests, onDone };
}

describe('while it runs', () => {
    it('shows a progress bar named for the pack, and what the Panel is doing', async () => {
        await follow([record('running', 30, 'Downloading server pack...')]);

        expect(await screen.findByText('Downloading the server pack…')).toBeTruthy();
        expect(screen.getByRole('progressbar', { name: 'Installing All the Mods 9' })).toBeTruthy();
        expect(screen.getByRole('heading', { name: 'Installing All the Mods 9' })).toBeTruthy();
    });

    it('says it is starting until the first answer', async () => {
        await follow([record('running', 0)]);

        expect(screen.getByText('Starting…')).toBeTruthy();
    });

    it('tells the person that leaving the page is fine', async () => {
        await follow([record('running', 10)]);

        expect(await screen.findByText(/You can leave this page/)).toBeTruthy();
    });

    it('asks for the record of this install, on the Panel’s own progress route', async () => {
        const { requests } = await follow([record('running', 10)]);

        await screen.findByText('Downloading the server pack…');
        expect(requests.some((request) => request.url.includes(`/api/client/servers/${SERVER_UUID}/extension-progress/modpack-installer/${JOB}`))).toBe(true);
    });
});

describe('stepText', () => {
    it.each([
        [0, 'Downloading the server pack…'],
        [49, 'Downloading the server pack…'],
        [50, 'Sending it to the server…'],
        [79, 'Sending it to the server…'],
        [80, 'Unpacking it…'],
        [94, 'Unpacking it…'],
        [95, 'Removing launch scripts that clash with the server’s own…'],
        [99, 'Removing launch scripts that clash with the server’s own…'],
    ])('at %i percent says %s', (percent, expected) => {
        expect(stepText(percent)).toBe(expected);
    });
});

describe('when it ends', () => {
    it('says the pack is installed, that a restart is needed, and offers another', async () => {
        const { onDone } = await follow([record('completed', 100, 'Modpack installed successfully.')]);

        expect(await screen.findByText('All the Mods 9 is installed')).toBeTruthy();
        expect(screen.getByText(/Restart the server/)).toBeTruthy();
        fireEvent.click(screen.getByRole('button', { name: 'Install another' }));
        expect(onDone).toHaveBeenCalledTimes(1);
    });

    it.each([
        ['source_unavailable', 'The modpack source did not answer'],
        ['file_not_found', 'That file is gone'],
        ['not_server_pack', 'This is not a server pack'],
        ['download_failed', 'The download failed'],
        ['download_too_large', 'That pack is too large'],
        ['upload_failed', 'The server did not accept the pack'],
        ['extract_failed', 'The pack could not be unpacked'],
        ['sanitize_failed', 'The pack is installed, but cleanup failed'],
        ['disk_full', 'The Panel has no room for the pack'],
    ])('says in words what the code %s means, and offers a way back', async (code, title) => {
        const { onDone } = await follow([record('failed', 0, code)]);

        const alert = await screen.findByRole('alert');
        expect(alert.textContent).toContain(title);
        expect(alert.textContent).not.toContain(code);
        fireEvent.click(screen.getByRole('button', { name: 'Back to the search' }));
        expect(onDone).toHaveBeenCalledTimes(1);
    });

    it('says the installation failed for a code it does not know', async () => {
        await follow([record('failed', 0, 'something_new')]);

        expect((await screen.findByRole('alert')).textContent).toContain('The installation failed');
    });

    it('says it lost track when the Panel has no record of the install, and suggests looking at the files', async () => {
        const { onDone } = await follow([{ status: 404 }]);

        expect(await screen.findByText('Lost track of the installation')).toBeTruthy();
        expect(screen.getByText(/Look at the server.s files/)).toBeTruthy();
        fireEvent.click(screen.getByRole('button', { name: 'Back to the search' }));
        expect(onDone).toHaveBeenCalledTimes(1);
    });
});
