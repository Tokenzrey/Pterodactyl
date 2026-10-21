import { cleanup, render, screen } from '@testing-library/react';
import { createExtensionTestHost, createTestServer, type ExtensionTestHost } from '@pterodactyl/sdk/testing';
import type { ReactElement } from 'react';
import { afterEach, vi } from 'vitest';

export const SERVER_UUID = '11111111-2222-4333-8444-555555555555';

let host: ExtensionTestHost | undefined;

/** Unmounts and disposes the panel host after each test; its query cache starts and ends empty. */
export function usePanelHost(): void {
    afterEach(() => {
        vi.useRealTimers();
        cleanup();
        host?.queryClient.clear();
        host?.dispose();
        host = undefined;
    });
}

/**
 * Renders inside the panel host, on a server the user has exactly these subuser permissions for. The host mounts
 * its router asynchronously, so a sentinel after the element tells when it has really rendered.
 */
export async function renderInPanel(ui: ReactElement, options: { permissions?: string[]; owner?: boolean } = {}) {
    host = createExtensionTestHost({
        extensionId: 'minecraft-suite',
        prefix: 'mcs',
        server: createTestServer({ uuid: SERVER_UUID, name: 'Survival', permissions: options.permissions ?? [], owner: options.owner ?? false }),
    });
    // No queryClient.clear() here: the host has just put the server in its cache, and a screen needs it there.

    const view = render(
        <>
            {ui}
            <i data-testid="settled" />
        </>,
        { wrapper: host.Wrapper },
    );
    await screen.findByTestId('settled');

    return view;
}
