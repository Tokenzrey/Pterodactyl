import { fireEvent, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { ErrorBanner } from './ErrorBanner';
import { ACCOUNT_ERRORS, LOGIN_ERRORS } from './messages';
import { ResultBanner } from './ResultBanner';
import { renderInPanel, usePanelHost } from './test-utils';

usePanelHost();
afterEach(() => window.history.pushState({}, '', '/'));

async function renderAt(search: string, ui = <ErrorBanner />) {
    window.history.pushState({}, '', `/auth/login${search}`);

    return renderInPanel(ui);
}

describe('ErrorBanner (AC-O19)', () => {
    it.each(Object.entries(LOGIN_ERRORS))('explains %s with a title and what to do next', async (code, notice) => {
        await renderAt(`?oauth_error=${code}`);

        const alert = screen.getByRole('alert');
        expect(alert.textContent).toContain(notice.title);
        expect(alert.textContent).toContain(notice.body);
    });

    it('covers every error code the backend can send', () => {
        // Keep in step with OauthLogin\Support\Errors::ALL (FR-O13).
        const codes = ['admin_blocked', 'denied', 'email_unverified', 'identity_conflict', 'invalid_state', 'no_account', 'provider_error', 'provider_unavailable', 'registration_failed', 'two_factor_required'];
        expect(Object.keys(LOGIN_ERRORS).sort()).toEqual(codes);
        expect(Object.keys(ACCOUNT_ERRORS).sort()).toEqual(codes);
    });

    it('every message is plain sentences: a title, and a body that says what to do', () => {
        for (const notice of Object.values(LOGIN_ERRORS)) {
            expect(notice.title.length).toBeGreaterThan(8);
            expect(notice.body.endsWith('.')).toBe(true);
            expect(notice.title.endsWith('.')).toBe(false);
        }
    });

    it.each([
        ['absent', ''],
        ['unknown', '?oauth_error=made_up'],
        ['empty', '?oauth_error='],
        ['markup', '?oauth_error=%3Cscript%3Ealert(1)%3C/script%3E'],
        ['inherited property names', '?oauth_error=__proto__'],
        ['a prototype method', '?oauth_error=toString'],
        ['constructor', '?oauth_error=constructor'],
        ['wrong case', '?oauth_error=NO_ACCOUNT'],
        ['padded', '?oauth_error=%20no_account'],
    ])('shows nothing for a %s code', async (_label, search) => {
        await renderAt(search);

        expect(screen.queryByRole('alert')).toBeNull();
    });

    it('never puts text from the URL on the page', async () => {
        const { container } = await renderAt('?oauth_error=no_account&oauth_error_description=EVIL-TEXT&message=EVIL-TEXT');

        expect(screen.getByRole('alert')).toBeTruthy();
        expect(container.textContent).not.toContain('EVIL-TEXT');
    });

    it('removes the message from the address once shown, keeping everything else', async () => {
        await renderAt('?oauth_error=no_account&keep=1#section');

        expect(window.location.search).toBe('?keep=1');
        expect(window.location.hash).toBe('#section');
        expect(screen.getByRole('alert')).toBeTruthy(); // still visible: only the address changed
    });

    it('can be dismissed', async () => {
        await renderAt('?oauth_error=no_account');

        fireEvent.click(screen.getByRole('button', { name: 'Dismiss' }));

        expect(screen.queryByRole('alert')).toBeNull();
    });
});

describe('ResultBanner on the account page', () => {
    it('confirms a connection by name', async () => {
        await renderAt('?oauth_linked=github', <ResultBanner context="account" />);

        expect(screen.getByRole('alert').textContent).toContain('GitHub connected');
    });

    it('ignores a provider this bundle does not know', async () => {
        await renderAt('?oauth_linked=gitlab', <ResultBanner context="account" />);

        expect(screen.queryByRole('alert')).toBeNull();
    });

    it('words failures for someone who is already signed in', async () => {
        await renderAt('?oauth_error=identity_conflict', <ResultBanner context="account" />);

        expect(screen.getByRole('alert').textContent).toContain(ACCOUNT_ERRORS.identity_conflict.title);
        expect(screen.getByRole('alert').textContent).not.toContain(LOGIN_ERRORS.identity_conflict.title);
    });
});
