export type Level = 'good' | 'warn' | 'bad' | 'unknown';

/** Healthy from 19 TPS, lagging from 15, struggling below that (FR-MS10). Nothing known is "unknown", never a colour. */
export function tpsLevel(tps: number | null): Level {
    if (tps === null) {
        return 'unknown';
    }

    return tps >= 19 ? 'good' : tps >= 15 ? 'warn' : 'bad';
}

/** The level in words, so colour is never the only signal. */
export const LEVEL_TEXT: Record<Level, string> = { good: 'Healthy', warn: 'Lagging', bad: 'Struggling', unknown: 'N/A' };

export const LEVEL_TONE: Record<Level, 'success' | 'warning' | 'danger' | 'neutral'> = { good: 'success', warn: 'warning', bad: 'danger', unknown: 'neutral' };

export function formatTps(tps: number | null): string {
    return tps === null ? 'N/A' : tps.toFixed(2);
}

export function formatMspt(mspt: number | null): string {
    return mspt === null ? 'N/A' : `${Number(mspt.toFixed(2))} ms`;
}

/** "45s", "5m", "1h 30m", "2d 3h": the two largest units that are not empty. */
export function formatUptime(seconds: number | null): string {
    if (seconds === null) {
        return 'N/A';
    }
    if (seconds < 60) {
        return `${seconds}s`;
    }
    if (seconds < 3600) {
        return `${Math.floor(seconds / 60)}m`;
    }
    if (seconds < 86400) {
        return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
    }

    return `${Math.floor(seconds / 86400)}d ${Math.floor((seconds % 86400) / 3600)}h`;
}
