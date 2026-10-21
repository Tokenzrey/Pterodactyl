import { useQuery } from '@tanstack/react-query';
import { DEFAULT_POLL_MS, fetchHealth } from './api';

/**
 * The server's health, asked again on the interval the server's settings give. It stops while the tab is hidden
 * and is not retried on its own after a failure: the next poll is the retry. The screen and the console widget use
 * the same key, so a page that shows both makes one request (FR-MS9).
 */
export function useHealth(uuid: string, enabled = true) {
    return useQuery({
        queryKey: ['minecraft-suite', 'health', uuid],
        queryFn: () => fetchHealth(uuid),
        enabled,
        refetchInterval: (query) => query.state.data?.pollMs ?? DEFAULT_POLL_MS,
        refetchIntervalInBackground: false,
        retry: false,
    });
}
