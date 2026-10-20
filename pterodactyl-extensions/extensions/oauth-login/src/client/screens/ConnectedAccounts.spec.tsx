import { fireEvent, screen, waitFor, within } from '@testing-library/react';
import { http } from '@pterodactyl/sdk';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderInPanel, usePanelHost } from '../test-utils';
import ConnectedAccounts from './ConnectedAccounts';

usePanelHost();

const LIST = {
    providers: [
        { id: 'discord', label: 'Discord', enabled: true, linked: true, linked_at: '2026-03-12T10:00:00+00:00' },
        { id: 'github', label: 'GitHub', enabled: true, linked: false, linked_at: null },
    ],
};

let providers: unknown;
let deleted: string[];

beforeEach(() => {
    providers = LIST.providers;
    deleted = [];
    vi.spyOn(http, 'get').mockImplementation((async () => ({ data: { providers } })) as never);
    vi.spyOn(http, 'delete').mockImplementation((async (url: string) => {
        deleted.push(url);
        providers = (providers as { id: string }[]).map((p) => (url.endsWith(`/${p.id}`) ? { ...p, linked: false, linked_at: null } : p));

        return { status: 204 };
    }) as never);
});
afterEach(() => {
    vi.restoreAllMocks();
    window.history.pushState({}, '', '/');
});

describe('Connected accounts', () => {
    it('lists the providers with their state and one action each', async () => {
        await renderInPanel(<ConnectedAccounts />);
        await screen.findByText('Discord');

        expect(screen.getByText(/^Connected \w{3} \d{1,2}, 2026$/)).toBeTruthy();
        expect(screen.getByText('Not connected')).toBeTruthy();
        expect(screen.getByRole('button', { name: 'Disconnect Discord' })).toBeTruthy();
        expect(screen.getByRole('link', { name: 'Connect GitHub' }).getAttribute('href')).toBe('/extensions/oauth-login/link/github');
    });

    it('explains what connecting does', async () => {
        await renderInPanel(<ConnectedAccounts />);

        expect(screen.getByText(/never your password/)).toBeTruthy();
    });

    it('asks before disconnecting, says what happens, and can be cancelled', async () => {
        await renderInPanel(<ConnectedAccounts />);
        await screen.findByText('Discord');

        fireEvent.click(screen.getByRole('button', { name: 'Disconnect Discord' }));

        const confirm = screen.getByRole('group', { name: 'Disconnect Discord?' });
        expect(confirm.textContent).toContain('You will no longer be able to sign in with Discord.');
        expect(confirm.textContent).toContain('set one in your account settings first');
        expect(deleted).toEqual([]);

        fireEvent.click(screen.getByRole('button', { name: 'Keep connected' }));

        expect(screen.queryByRole('group')).toBeNull();
        expect(deleted).toEqual([]);
    });

    it('disconnects after confirmation and shows the provider as not connected', async () => {
        await renderInPanel(<ConnectedAccounts />);
        await screen.findByText('Discord');

        fireEvent.click(screen.getByRole('button', { name: 'Disconnect Discord' }));
        fireEvent.click(screen.getByRole('button', { name: 'Yes, disconnect' }));

        await waitFor(() => expect(deleted).toEqual(['/api/client/extensions/oauth-login/accounts/discord']));
        expect(await screen.findByRole('link', { name: 'Connect Discord' })).toBeTruthy();
        expect(screen.queryByRole('group')).toBeNull();
    });

    it('a provider an administrator turned off can still be disconnected, and says so', async () => {
        providers = [{ id: 'discord', label: 'Discord', enabled: false, linked: true, linked_at: '2026-03-12T10:00:00+00:00' }];

        await renderInPanel(<ConnectedAccounts />);

        expect(await screen.findByText(/turned off by an administrator/)).toBeTruthy();
        expect(screen.getByRole('button', { name: 'Disconnect Discord' })).toBeTruthy();
    });

    it('shows an empty state with the way forward when nothing is set up', async () => {
        providers = [];

        await renderInPanel(<ConnectedAccounts />);

        expect(await screen.findByText('No sign-in providers are set up')).toBeTruthy();
        expect(screen.getByText(/Admin → Extensions → OAuth Login/)).toBeTruthy();
    });

    it('says when the list cannot be loaded, without an apology or a stack trace', async () => {
        vi.mocked(http.get).mockImplementation((async () => {
            throw new Error('boom at /var/www/secret/path');
        }) as never);

        await renderInPanel(<ConnectedAccounts />);

        expect(await screen.findByText('Could not load your connected accounts', {}, { timeout: 4000 })).toBeTruthy();
        expect(document.body.textContent).not.toContain('/var/www');
    });

    it('drops entries that are not well formed instead of guessing', async () => {
        providers = [{ id: 'gitlab', label: 'GitLab', enabled: true, linked: false }, { id: 'github', label: 'GitHub', enabled: 'yes', linked: false }, LIST.providers[1]];

        await renderInPanel(<ConnectedAccounts />);

        expect(await screen.findByText('GitHub')).toBeTruthy();
        expect(screen.queryByText('GitLab')).toBeNull();
        expect(within(screen.getByRole('list')).getAllByRole('link')).toHaveLength(1);
    });

    it('shows the result of a connect attempt from the address, then cleans the address', async () => {
        window.history.pushState({}, '', '/account/connected-accounts?oauth_linked=github');

        await renderInPanel(<ConnectedAccounts />);

        expect(screen.getByRole('alert').textContent).toContain('GitHub connected');
        expect(window.location.search).toBe('');
    });

    it('shows a failed connect attempt in words for a signed-in person', async () => {
        window.history.pushState({}, '', '/account/connected-accounts?oauth_error=identity_conflict');

        await renderInPanel(<ConnectedAccounts />);

        expect(screen.getByRole('alert').textContent).toContain('That account cannot be connected');
    });
});
