import { fireEvent, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { LoginButtons } from './LoginButtons';
import { renderInPanel, usePanelHost } from './test-utils';

usePanelHost();

beforeEach(() => window.localStorage.clear());
afterEach(() => vi.restoreAllMocks());

/** A click that does not navigate: jsdom would otherwise log "not implemented: navigation". */
function click(element: HTMLElement) {
    const event = new MouseEvent('click', { bubbles: true, cancelable: true });
    element.addEventListener('click', (e) => e.preventDefault(), { once: true });
    fireEvent(element, event);

    return event;
}

describe('LoginButtons (AC-O19)', () => {
    it('draws one plain link per enabled provider, pointing at the redirect endpoint', async () => {
        await renderInPanel(<LoginButtons providers={['discord', 'github', 'google']} />);

        const links = screen.getAllByRole('link');
        expect(links.map((link) => link.textContent)).toEqual(['Continue with Discord', 'Continue with GitHub', 'Continue with Google']);
        expect(links.map((link) => link.getAttribute('href'))).toEqual([
            '/extensions/oauth-login/redirect/discord',
            '/extensions/oauth-login/redirect/github',
            '/extensions/oauth-login/redirect/google',
        ]);
    });

    it('says what the buttons are for: a labelled "or continue with" divider', async () => {
        await renderInPanel(<LoginButtons providers={['discord']} />);

        expect(screen.getByRole('region', { name: 'or continue with' })).toBeTruthy();
    });

    it('shows the mark of each provider, hidden from screen readers (the text carries the name)', async () => {
        const { container } = await renderInPanel(<LoginButtons providers={['discord', 'github', 'google']} />);

        const icons = container.querySelectorAll('svg');
        expect(icons).toHaveLength(3);
        icons.forEach((icon) => expect(icon.getAttribute('aria-hidden')).toBe('true'));
    });

    it('only draws what is enabled', async () => {
        await renderInPanel(<LoginButtons providers={['discord']} />);

        expect(screen.getAllByRole('link')).toHaveLength(1);
        expect(screen.getByRole('link').getAttribute('href')).toBe('/extensions/oauth-login/redirect/discord');
    });

    it('draws nothing when no provider is enabled', async () => {
        const { container } = await renderInPanel(<LoginButtons providers={[]} />);

        expect(screen.queryByRole('region')).toBeNull();
        expect(container.querySelector('a')).toBeNull();
    });

    it('uses real anchors that open a normal page load (the browser has to leave the panel)', async () => {
        await renderInPanel(<LoginButtons providers={['google']} />);

        const link = screen.getByRole('link');
        expect(link.tagName).toBe('A');
        expect(link.getAttribute('target')).toBeNull();
        expect(link.getAttribute('href')?.startsWith('/')).toBe(true);
    });

    it('puts the provider used last first and marks it', async () => {
        window.localStorage.setItem('oauth-login:last-provider', 'google');

        await renderInPanel(<LoginButtons providers={['discord', 'github', 'google']} />);

        expect(screen.getAllByRole('link').map((link) => link.getAttribute('href')?.split('/').pop())).toEqual(['google', 'discord', 'github']);
        expect(screen.getByText('Last used')).toBeTruthy();
    });

    it('ignores a remembered provider that is no longer offered, or garbage', async () => {
        window.localStorage.setItem('oauth-login:last-provider', 'github');
        await renderInPanel(<LoginButtons providers={['discord']} />);
        expect(screen.queryByText('Last used')).toBeNull();
    });

    it('ignores garbage in storage', async () => {
        window.localStorage.setItem('oauth-login:last-provider', '<script>alert(1)</script>');

        await renderInPanel(<LoginButtons providers={['discord', 'github']} />);

        expect(screen.queryByText('Last used')).toBeNull();
        expect(screen.getAllByRole('link')[0].getAttribute('href')).toBe('/extensions/oauth-login/redirect/discord');
    });

    it('works when storage is blocked', async () => {
        vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
            throw new DOMException('blocked', 'SecurityError');
        });
        vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
            throw new DOMException('blocked', 'SecurityError');
        });

        await renderInPanel(<LoginButtons providers={['discord', 'github']} />);
        click(screen.getByRole('link', { name: /Discord/ }));

        expect(screen.getByRole('link', { name: /Opening Discord/ })).toBeTruthy();
    });

    it('after a click: remembers the choice, shows it is opening, and ignores further clicks', async () => {
        await renderInPanel(<LoginButtons providers={['discord', 'github']} />);

        const first = click(screen.getByRole('link', { name: /Discord/ }));

        expect(first.defaultPrevented).toBe(true); // only because the test stops the navigation itself
        expect(window.localStorage.getItem('oauth-login:last-provider')).toBe('discord');
        expect(screen.getByRole('link', { name: 'Opening Discord…' })).toBeTruthy();
        expect(screen.getByRole('list').getAttribute('aria-busy')).toBe('true');

        const other = screen.getByRole('link', { name: /GitHub/ });
        expect(other.getAttribute('aria-disabled')).toBe('true');
        click(other);
        expect(window.localStorage.getItem('oauth-login:last-provider')).toBe('discord');
    });

    it('goes back to normal when the page is restored from the back/forward cache', async () => {
        await renderInPanel(<LoginButtons providers={['discord']} />);
        click(screen.getByRole('link', { name: /Discord/ }));
        expect(screen.getByRole('link', { name: /Opening/ })).toBeTruthy();

        fireEvent(window, new Event('pageshow'));

        expect(await screen.findByRole('link', { name: 'Continue with Discord' })).toBeTruthy();
    });
});
