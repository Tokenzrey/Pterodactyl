import { PROVIDER_IDS, type ProviderId } from './config';

const KEY = 'oauth-login:last-provider';

/** The provider this browser signed in with last, if it is still on offer. Storage may be blocked: then there is none. */
export function readLastProvider(offered: readonly ProviderId[]): ProviderId | null {
    try {
        const stored = window.localStorage.getItem(KEY);

        return PROVIDER_IDS.find((id) => id === stored && offered.includes(id)) ?? null;
    } catch {
        return null;
    }
}

export function rememberProvider(id: ProviderId): void {
    try {
        window.localStorage.setItem(KEY, id);
    } catch {
        // A convenience only; the sign-in itself does not depend on it.
    }
}
