/** The only address an avatar is ever loaded from. It is a constant, never a setting or a value from a response (NFR-PM6). */
export const CRAFATAR_BASE = 'https://crafatar.com/';

const PATHS = { avatar: 'avatars', head: 'renders/head', body: 'renders/body', cape: 'capes' } as const;

export type CrafatarType = keyof typeof PATHS;

// All hyphens or none: the optional hyphen is captured once and must repeat.
const UUID = /^([0-9a-f]{8})(-?)([0-9a-f]{4})\2([0-9a-f]{4})\2([0-9a-f]{4})\2([0-9a-f]{12})$/i;

/** A UUID with or without hyphens, written with hyphens in lower case. Anything else is null. */
export function normalizeUuid(value: unknown): string | null {
    const match = typeof value === 'string' ? UUID.exec(value) : null;

    return match ? [match[1], match[3], match[4], match[5], match[6]].join('-').toLowerCase() : null;
}

/** A Crafatar image URL for a valid UUID, or null. The size is put in only when it is a whole number Crafatar serves. */
export function crafatarUrl(type: CrafatarType, uuid: string | null, size?: number): string | null {
    const id = normalizeUuid(uuid);
    if (id === null) {
        return null;
    }

    const query = size !== undefined && Number.isInteger(size) && size >= 1 && size <= 512 ? `?size=${size}` : '';

    return `${CRAFATAR_BASE}${PATHS[type]}/${id}${query}`;
}
