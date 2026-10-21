import { cleanup, render, screen } from '@testing-library/react';
import { http } from '@pterodactyl/sdk';
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
        extensionId: 'file-transfer',
        prefix: 'ftr',
        server: createTestServer({ uuid: SERVER_UUID, name: 'Survival', permissions: options.permissions ?? [], owner: options.owner ?? false }),
    });
    // No queryClient.clear() here: the host has just put the server in its cache.

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

interface FakeRequest {
    method: string;
    url: string;
    body: unknown;
    /** The signal the request was made with, if any. */
    signal?: AbortSignal;
}

/** What a fake answer is: a status, a body, and optionally headers. A status of 400 or more rejects like a real failed request. */
export interface FakeReply {
    status?: number;
    data?: unknown;
    headers?: Record<string, string>;
}

/**
 * Replaces the network under the Panel's HTTP client for one test. Everything that goes through it, the extension's own
 * calls and the Panel's generated progress client alike, is answered by `answer`; every request is also recorded.
 * Restored after each test.
 */
export function fakeNetwork(answer: (request: FakeRequest) => FakeReply | Promise<FakeReply>): FakeRequest[] {
    const requests: FakeRequest[] = [];
    const original = http.defaults.adapter;

    http.defaults.adapter = async (config) => {
        const request: FakeRequest = {
            method: String(config.method ?? 'get').toLowerCase(),
            url: String(config.url ?? ''),
            body: typeof config.data === 'string' ? JSON.parse(config.data) : config.data,
            signal: config.signal as AbortSignal | undefined,
        };
        requests.push(request);
        const reply = await Promise.race([answer(request), cancelled(request.signal)]);
        const response = { data: reply.data ?? {}, status: reply.status ?? 200, statusText: '', headers: reply.headers ?? {}, config, request: {} };

        if (response.status >= 400) {
            throw Object.assign(new Error(`Request failed with status code ${response.status}`), { isAxiosError: true, config, response });
        }

        return response;
    };
    restore.push(() => {
        http.defaults.adapter = original;
    });

    return requests;
}

/** Rejects when the signal fires, as a real request does, and never settles without one. */
function cancelled(signal?: AbortSignal): Promise<never> {
    return new Promise((_resolve, reject) => {
        const fail = () => reject(Object.assign(new Error('canceled'), { code: 'ERR_CANCELED' }));
        if (signal?.aborted) {
            fail();
        } else {
            signal?.addEventListener('abort', fail, { once: true });
        }
    });
}

const restore: Array<() => void> = [];

afterEach(() => {
    while (restore.length > 0) {
        restore.pop()?.();
    }
});
