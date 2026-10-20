import { cleanup, render, screen } from '@testing-library/react';
import { createExtensionTestHost, type ExtensionTestHost } from '@pterodactyl/sdk/testing';
import type { ReactElement } from 'react';
import { afterEach, beforeEach } from 'vitest';

let host: ExtensionTestHost;

/** One panel test host per test, unmounted before it is disposed (the SDK shares one query cache between hosts). */
export function usePanelHost(): void {
    beforeEach(() => {
        host = createExtensionTestHost({ extensionId: 'oauth-login', prefix: 'olg' });
    });
    afterEach(() => {
        cleanup();
        host.dispose();
    });
}

/**
 * Renders inside the panel host. The host mounts its router asynchronously, so a "nothing is shown"
 * assertion made straight away would pass for the wrong reason; a sentinel after the element tells
 * when the host has really rendered.
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
