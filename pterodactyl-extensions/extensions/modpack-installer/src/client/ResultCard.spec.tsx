import { fireEvent, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { ModpackFile, ModpackResult } from './api';
import { ResultCard } from './ResultCard';
import { renderInPanel, usePanelHost } from './test-utils';

usePanelHost();

const file = (over: Partial<ModpackFile> = {}): ModpackFile => ({ file_id: '4002', name: 'atm9-1.0.0.zip', game_version: '1.20.1', loader: 'forge', is_server_pack: true, file_size_mb: 250.5, ...over });
const result = (over: Partial<ModpackResult> = {}): ModpackResult => ({
    source: 'curseforge',
    project_id: '123',
    name: 'All the Mods 9',
    summary: 'Everything.',
    downloads: 5000000,
    icon_url: 'https://media.forgecdn.net/atm9.png',
    latest_files: [file()],
    ...over,
});

async function show(over: Partial<ModpackResult> = {}, busy = false) {
    const onInstall = vi.fn();
    const { container } = await renderInPanel(
        <ul>
            <ResultCard result={result(over)} busy={busy} onInstall={onInstall} />
        </ul>,
        { owner: true },
    );

    return { onInstall, container };
}

describe('what it shows', () => {
    it('names the pack, says what it is, and how many have downloaded it', async () => {
        await show();

        expect(screen.getByRole('heading', { name: 'All the Mods 9' })).toBeTruthy();
        expect(screen.getByText('Everything.')).toBeTruthy();
        expect(screen.getByText('5,000,000 downloads')).toBeTruthy();
    });

    it('shows each file with its version, loader and size', async () => {
        await show();

        expect(screen.getByText('atm9-1.0.0.zip')).toBeTruthy();
        expect(screen.getByText('1.20.1')).toBeTruthy();
        expect(screen.getByText('forge')).toBeTruthy();
        expect(screen.getByText('250.5 MB')).toBeTruthy();
    });

    it('shows the icon as decoration, and tells the browser to keep the page private', async () => {
        const { container } = await show();
        const icon = container.querySelector('img') as HTMLImageElement;

        expect(icon.getAttribute('src')).toBe('https://media.forgecdn.net/atm9.png');
        expect(icon.getAttribute('alt')).toBe('');
        expect(icon.getAttribute('referrerpolicy')).toBe('no-referrer');
    });

    it('shows a plain block when there is no icon', async () => {
        const { container } = await show({ icon_url: null });

        expect(container.querySelector('img')).toBeNull();
    });

    it('leaves out the summary when it is empty', async () => {
        await show({ summary: '' });

        expect(screen.queryByText('Everything.')).toBeNull();
    });

    it('shows text from the source as text, never as markup', async () => {
        const { container } = await show({ name: '<img src=x onerror=alert(1)>', summary: '<script>alert(1)</script>' });

        expect(screen.getByRole('heading').textContent).toBe('<img src=x onerror=alert(1)>');
        expect(container.querySelector('script')).toBeNull();
        expect(container.querySelectorAll('img')).toHaveLength(1);
    });
});

describe('installing (FR-MI13, AC-MI17)', () => {
    it('offers the install button for a server pack, named for the file and the pack', async () => {
        await show();

        expect(screen.getByRole('button', { name: 'Install the server pack of atm9-1.0.0.zip, from All the Mods 9' })).toBeTruthy();
    });

    it('hands the pack and the file on when the button is pressed', async () => {
        const { onInstall } = await show();

        fireEvent.click(screen.getByRole('button', { name: /Install the server pack/ }));

        expect(onInstall).toHaveBeenCalledWith(expect.objectContaining({ project_id: '123' }), expect.objectContaining({ file_id: '4002' }));
    });

    it('has no button for a file that is not a server pack, and says so', async () => {
        await show({ latest_files: [file({ is_server_pack: false })] });

        expect(screen.queryByRole('button')).toBeNull();
        expect(screen.getByText('No server pack')).toBeTruthy();
    });

    it('offers a button only to the files that can be installed', async () => {
        await show({ latest_files: [file({ file_id: '1', name: 'client.zip', is_server_pack: false }), file({ file_id: '2', name: 'server.zip' })] });

        expect(screen.getAllByRole('button')).toHaveLength(1);
        expect(screen.getByRole('button').getAttribute('aria-label')).toContain('server.zip');
    });

    it('disables the buttons while another install is being set up', async () => {
        await show({}, true);

        expect((screen.getByRole('button') as HTMLButtonElement).disabled).toBe(true);
    });

    it('says what is missing when there are no files', async () => {
        await show({ latest_files: [] });
        expect(screen.getByText('No files are listed for this pack.')).toBeTruthy();
    });

    it('says Modrinth has no server packs, rather than leaving a card with nothing to do', async () => {
        await show({ source: 'modrinth', latest_files: [] });

        expect(screen.getByText('Modrinth has no server packs to install.')).toBeTruthy();
    });

    it('leaves out a size, a version and a loader that are not known', async () => {
        await show({ latest_files: [file({ game_version: null, loader: null, file_size_mb: null })] });

        expect(screen.queryByText('1.20.1')).toBeNull();
        expect(screen.queryByText('forge')).toBeNull();
        expect(screen.queryByText(/MB/)).toBeNull();
    });
});
