import { screen } from '@testing-library/react';
import { http, type SdkServer, type SlotComponentProps } from '@pterodactyl/sdk';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import AddressWidget from './AddressWidget';
import { renderInPanel, usePanelHost } from './test-utils';

// The owner's address above the console: the name, whether it is routed, and when the port must be typed too.

usePanelHost();

const ADDRESS = (over: Record<string, unknown> = {}) => ({
    address: 'kampung.mc.example.com', status: 'active', mode: 'routed', needs_port: false, routing: { state: 'ready', reason: null }, ...over,
});

const props = { data: { attributes: { uuid: 'u-1' } } as unknown as SdkServer } as SlotComponentProps<SdkServer>;

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

describe('the owner address above the console', () => {
    it('shows the name players type, with a copy button', async () => {
        await renderInPanel(<AddressWidget {...props} />);

        expect(await screen.findByText('kampung.mc.example.com')).toBeTruthy();
        expect(screen.getByText('Players join with')).toBeTruthy();
        expect(screen.getByRole('button', { name: 'Copy address' })).toBeTruthy();
    });

    it('says the name is routed when games sync routes it', async () => {
        await renderInPanel(<AddressWidget {...props} />);

        expect(await screen.findByText('Routed to this server.')).toBeTruthy();
    });

    it('says why it is not routed', async () => {
        answer = ADDRESS({ routing: { state: 'invalid', reason: 'the allocation is 0.0.0.0, not 127.0.0.1' } });
        await renderInPanel(<AddressWidget {...props} />);

        expect(await screen.findByText('Not routed: the allocation is 0.0.0.0, not 127.0.0.1.')).toBeTruthy();
    });

    it('asks for the port too when the name alone does not carry it', async () => {
        answer = ADDRESS({ mode: 'per_port', needs_port: true, routing: null });
        await renderInPanel(<AddressWidget {...props} />);

        expect(await screen.findByText('Add the server port after the name.')).toBeTruthy();
    });

    it('says there is no address yet, without inventing one', async () => {
        answer = ADDRESS({ address: null, status: null, routing: null });
        await renderInPanel(<AddressWidget {...props} />);

        expect(await screen.findByText(/No address yet/)).toBeTruthy();
        expect(screen.queryByText('Players join with')).toBeNull();
    });

    it('says the address is unavailable when the answer cannot be read, and shows nothing else', async () => {
        vi.mocked(http.get).mockImplementation((async () => ({ data: 'not an object' })) as never);
        await renderInPanel(<AddressWidget {...props} />);

        expect(await screen.findByText('Address unavailable', {}, { timeout: 3000 })).toBeTruthy();
    });
});
