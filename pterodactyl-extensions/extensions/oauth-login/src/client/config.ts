import type { ExtensionConfig } from '@pterodactyl/sdk';

/** Fixed order, so the buttons never move around whatever order the administrator ticked them in. */
export const PROVIDER_IDS = ['discord', 'github', 'google'] as const;

export type ProviderId = (typeof PROVIDER_IDS)[number];

// A type alias, not an interface: the SDK wants a config assignable to `{ [key: string]: ExtensionConfigValue }`.
export type OauthConfig = { readonly providers: readonly ProviderId[] };

/**
 * Decodes what the panel hands every visitor of the login page: the `enabled_providers` list.
 * Anything that is not one of the three known ids (a typo, an id from a newer version, junk) is dropped
 * rather than turned into a link.
 */
export function parseConfig(config: ExtensionConfig): OauthConfig {
    const raw: readonly unknown[] = Array.isArray(config.enabled_providers) ? config.enabled_providers : [];

    return { providers: PROVIDER_IDS.filter((id) => raw.includes(id)) };
}
