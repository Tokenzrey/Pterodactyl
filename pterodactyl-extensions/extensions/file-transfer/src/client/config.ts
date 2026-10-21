import type { ExtensionConfig } from '@pterodactyl/sdk';

// A type alias, not an interface: the SDK wants a config assignable to `{ [key: string]: ExtensionConfigValue }`.
export type TransferConfig = { readonly chunkSizeMb: number; readonly maxFileMb: number };

const whole = (value: unknown, low: number, high: number, fallback: number): number =>
    typeof value === 'number' && Number.isInteger(value) && value >= low && value <= high ? value : fallback;

/**
 * Decodes what the panel hands every page: the two public settings, the size of a piece (1 to 10 MB, 5 by default) and
 * the largest file (1 to 10240 MB, 2048 by default). Anything outside those ranges is the default, never a surprise.
 */
export function parseConfig(config: ExtensionConfig): TransferConfig {
    return {
        chunkSizeMb: whole(config.chunk_size_mb, 1, 10, 5),
        maxFileMb: whole(config.max_file_mb, 1, 10240, 2048),
    };
}
