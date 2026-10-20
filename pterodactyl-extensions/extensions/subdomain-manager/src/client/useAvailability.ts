import { useEffect, useState } from 'react';
import { checkAvailability, type Availability } from './api';

export const DEBOUNCE_MS = 500;

export type AvailabilityState = { kind: 'idle' } | { kind: 'checking' } | { kind: 'done'; answer: Availability } | { kind: 'failed' };

/**
 * Asks the backend whether `label` under `domain` is free, 500 ms after the last change. A newer input
 * cancels both the wait and a request already on its way, so an old answer can never overwrite a newer one.
 * `enabled` false (empty or locally invalid input) asks nothing.
 */
export function useAvailability(domain: string, label: string, server: number | undefined, enabled: boolean): AvailabilityState {
    const [state, setState] = useState<AvailabilityState>({ kind: 'idle' });

    useEffect(() => {
        if (!enabled) {
            setState({ kind: 'idle' });

            return;
        }

        const controller = new AbortController();
        const timer = setTimeout(() => {
            setState({ kind: 'checking' });
            checkAvailability({ domain, label, server }, controller.signal).then(
                (answer) => {
                    if (!controller.signal.aborted) {
                        setState({ kind: 'done', answer });
                    }
                },
                () => {
                    if (!controller.signal.aborted) {
                        setState({ kind: 'failed' });
                    }
                },
            );
        }, DEBOUNCE_MS);

        // Between keystrokes the old answer would describe a name that is no longer in the box.
        setState({ kind: 'idle' });

        return () => {
            clearTimeout(timer);
            controller.abort();
        };
    }, [domain, label, server, enabled]);

    return state;
}
