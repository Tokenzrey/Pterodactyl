import { cleanup, render, screen } from '@testing-library/react';
import { createExtensionTestHost, type ExtensionTestHost } from '@pterodactyl/sdk/testing';
import type { ReactElement } from 'react';
import { afterEach, beforeEach, vi } from 'vitest';

let host: ExtensionTestHost;

/** One panel test host per test, unmounted before it is disposed; its query cache starts and ends empty. */
export function usePanelHost(): void {
    beforeEach(() => {
        host = createExtensionTestHost({ extensionId: 'subdomain-manager', prefix: 'sdm' });
        host.queryClient.clear();
    });
    afterEach(() => {
        vi.useRealTimers();
        cleanup();
        host.queryClient.clear();
        host.dispose();
    });
}

/**
 * Renders inside the panel host. The host mounts its router asynchronously, so a sentinel after the element
 * tells when it has really rendered (a "nothing is shown" assertion made earlier would pass for the wrong reason).
 */
export async function renderInPanel(ui: ReactElement) {
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
