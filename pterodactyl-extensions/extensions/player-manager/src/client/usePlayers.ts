import { useQuery } from '@tanstack/react-query';
import { DEFAULT_POLL_MS, fetchPlayers } from './api';

/** "3 / 20 players online", or "3 players online" when the maximum is not known. */
export function countText(online: number, max: number | null): string {
    return max === null ? `${online} ${online === 1 ? 'player' : 'players'} online` : `${online} / ${max} players online`;
}

/**
 * The player list, asked again on the interval the server's settings give. It stops while the tab is hidden and
 * is not retried on its own after a failure: the next poll is the retry. The screen and the console widget use the
 * same key, so a page that shows both makes one request (FR-PM13).
 */
export function usePlayers(uuid: string, enabled = true) {
    return useQuery({
        queryKey: ['player-manager', 'players', uuid],
        queryFn: () => fetchPlayers(uuid),
        enabled,
        refetchInterval: (query) => query.state.data?.pollMs ?? DEFAULT_POLL_MS,
        refetchIntervalInBackground: false,
        retry: false,
    });
}
