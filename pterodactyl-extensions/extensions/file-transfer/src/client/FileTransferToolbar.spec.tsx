import { fireEvent, screen } from '@testing-library/react';
import { createTestFileManager } from '@pterodactyl/sdk/testing';
import { describe, expect, it } from 'vitest';
import { FileTransferToolbar } from './FileTransferToolbar';
import { fakeNetwork, renderInPanel, usePanelHost } from './test-utils';

// The two toolbar buttons show only to someone who may use them, and each opens its own dialog.

usePanelHost();

const config = { chunkSizeMb: 5, maxFileMb: 2048 };
const slot = (refresh: () => Promise<void> = async () => {}) => ({ ...createTestFileManager().slot, directory: '/plugins', refresh });
const toolbar = (refresh?: () => Promise<void>) => <FileTransferToolbar data={slot(refresh)} config={config} />;

describe('who sees which button', () => {
    it('shows both to someone who may create files and fetch', async () => {
        await renderInPanel(toolbar(), { permissions: ['file.create', 'ext.file-transfer.remote-fetch'] });

        expect(screen.getByRole('button', { name: /upload large file/i })).toBeTruthy();
        expect(screen.getByRole('button', { name: /fetch from address/i })).toBeTruthy();
    });

    it('shows only the upload to someone who may not fetch', async () => {
        await renderInPanel(toolbar(), { permissions: ['file.create'] });

        expect(screen.getByRole('button', { name: /upload large file/i })).toBeTruthy();
        expect(screen.queryByRole('button', { name: /fetch from address/i })).toBeNull();
    });

    it('shows only the fetch to someone who holds the fetch permission alone (FR-FT14)', async () => {
        await renderInPanel(toolbar(), { permissions: ['ext.file-transfer.remote-fetch'] });

        expect(screen.getByRole('button', { name: /fetch from address/i })).toBeTruthy();
        expect(screen.queryByRole('button', { name: /upload large file/i })).toBeNull();
    });

    it('shows nothing to someone with neither', async () => {
        await renderInPanel(toolbar(), { permissions: ['file.read'] });

        expect(screen.queryByRole('button')).toBeNull();
    });

    it('shows both to the owner, who has every permission', async () => {
        await renderInPanel(toolbar(), { owner: true });

        expect(screen.getAllByRole('button')).toHaveLength(2);
    });
});

describe('opening a dialog', () => {
    it('opens the upload dialog for the folder being shown, and closes it again', async () => {
        fakeNetwork(() => ({}));
        await renderInPanel(toolbar(), { permissions: ['file.create'] });

        fireEvent.click(screen.getByRole('button', { name: /upload large file/i }));

        expect(await screen.findByRole('dialog', { name: /upload a large file/i })).toBeTruthy();
        expect(screen.getByText(/to \/plugins on this server/)).toBeTruthy();

        fireEvent.click(screen.getByRole('button', { name: 'Close' }));
        expect(screen.queryByRole('dialog')).toBeNull();
    });

    it('opens the fetch dialog', async () => {
        fakeNetwork(() => ({}));
        await renderInPanel(toolbar(), { permissions: ['file.create', 'ext.file-transfer.remote-fetch'] });

        fireEvent.click(screen.getByRole('button', { name: /fetch from address/i }));

        expect(await screen.findByRole('dialog', { name: /fetch a file from an address/i })).toBeTruthy();
    });
});
