import { screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import extension from './index';
import { renderInPanel, usePanelHost } from './test-utils';

usePanelHost();
beforeEach(() => window.localStorage.clear());

/** What the panel passes to `setup`; only the parts this extension uses. */
function setUp(enabledProviders: readonly string[]) {
    const slot = vi.fn();
    const screens = vi.fn();
    extension.setup({ meta: { id: 'oauth-login' }, config: { enabled_providers: enabledProviders }, slots: { register: slot }, screens: { register: screens } } as never);

    return { slot, screens };
}

describe('extension entry', () => {
    it('mounts the buttons under the login form and the banner above it', () => {
        const { slot } = setUp(['discord']);

        expect(slot.mock.calls.map(([name]) => name).sort()).toEqual(['auth.login.before', 'auth.login.form.after']);
    });

    it('registers the Connected accounts screen declared in the manifest', () => {
        const { screens } = setUp(['discord']);

        expect(screens.mock.calls.map(([id]) => id)).toEqual(['accounts']);
        expect(typeof screens.mock.calls[0][1]).toBe('function');
    });

    it('passes the decoded configuration to the buttons', async () => {
        const { slot } = setUp(['google', 'discord', 'bogus']);
        const Buttons = slot.mock.calls.find(([name]) => name === 'auth.login.form.after')?.[1] as () => React.ReactElement;

        await renderInPanel(<Buttons />);

        expect(screen.getAllByRole('link').map((link) => link.getAttribute('href'))).toEqual([
            '/extensions/oauth-login/redirect/discord',
            '/extensions/oauth-login/redirect/google',
        ]);
    });
});
