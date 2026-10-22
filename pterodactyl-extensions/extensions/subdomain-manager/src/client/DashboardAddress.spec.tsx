import { screen } from '@testing-library/react';
import { http, type SdkServer, type SlotComponentProps } from '@pterodactyl/sdk';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import DashboardAddress from './DashboardAddress';
import { renderInPanel, usePanelHost } from './test-utils';

// The owner's dashboard: the address under the server's name, and nothing at all when there is none.

usePanelHost();

const ADDRESS = (over: Record<string, unknown> = {}) => ({
    address: 'kampung.mc.example.com', status: 'active', mode: 'routed', needs_port: false, routing: { state: 'ready', reason: null }, ...over,
});

const props = { data: { attributes: { uuid: 'u-2' } } as unknown as SdkServer } as SlotComponentProps<SdkServer>;

let answer: unknown;

beforeEach(() => {
    answer = ADDRESS();
    vi.spyOn(http, 'get').mockImplementation((async (url: string) => {
        if (url.endsWith('/extensions/subdomain-manager/address')) {
            return { data: answer };
        }
        throw new Error(`unexpected ${url}`);
    }) as never);
});

afterEach(() => {
    vi.restoreAllMocks();
});

describe('the address on the dashboard', () => {
    it('shows the name under the server name', async () => {
        await renderInPanel(<DashboardAddress {...props} />);

        expect(await screen.findByText('kampung.mc.example.com')).toBeTruthy();
    });

    it('marks a name that is not routed, with no long explanation on the list', async () => {
        answer = ADDRESS({ routing: { state: 'invalid', reason: 'the server is suspended' } });
        await renderInPanel(<DashboardAddress {...props} />);

        expect(await screen.findByText(/kampung\.mc\.example\.com/)).toBeTruthy();
        expect(document.body.textContent).toContain('not routed');
        expect(document.body.textContent).not.toContain('the server is suspended');
    });

    it('shows nothing when the server has no address, so the list looks as before', async () => {
        answer = ADDRESS({ address: null, status: null, routing: null });
        const { container } = await renderInPanel(<DashboardAddress {...props} />);

        await vi.waitFor(() => expect(http.get).toHaveBeenCalled());
        expect(container.textContent).toBe('');
    });

    it('shows nothing when the answer cannot be read', async () => {
        vi.mocked(http.get).mockImplementation((async () => ({ data: 'not an object' })) as never);
        const { container } = await renderInPanel(<DashboardAddress {...props} />);

        await new Promise((resolve) => setTimeout(resolve, 500));
        expect(container.textContent).toBe('');
    });
});
