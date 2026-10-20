import { http } from '@pterodactyl/sdk';
import { PROVIDER_IDS, type ProviderId } from './config';

const BASE = '/api/client/extensions/oauth-login/accounts';

export interface AccountProvider {
    id: ProviderId;
    label: string;
    enabled: boolean;
    linked: boolean;
    linked_at: string | null;
}

/** Providers this person can connect or has connected. Entries that are not well formed are dropped, not guessed at. */
export async function fetchAccounts(): Promise<AccountProvider[]> {
    const { data } = await http.get<unknown>(BASE);
    const list = (data as { providers?: unknown } | null)?.providers;
    if (!Array.isArray(list)) {
        throw new Error('The connected accounts have an unexpected shape.');
    }

    const providers: AccountProvider[] = [];
    for (const item of list as Record<string, unknown>[]) {
        const id = PROVIDER_IDS.find((known) => known === item?.id);
        if (id && typeof item.label === 'string' && typeof item.enabled === 'boolean' && typeof item.linked === 'boolean') {
            providers.push({ id, label: item.label, enabled: item.enabled, linked: item.linked, linked_at: typeof item.linked_at === 'string' ? item.linked_at : null });
        }
    }

    return providers;
}

export async function disconnectAccount(id: ProviderId): Promise<void> {
    await http.delete(`${BASE}/${id}`);
}
