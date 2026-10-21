import { describe, expect, it } from 'vitest';
import { formatMspt, formatTps, formatUptime, LEVEL_TEXT, tpsLevel } from './health';

// FR-MS10, AC-MS12: green from 19, yellow from 15, red below; null is "N/A", never a colour.

describe('tpsLevel', () => {
    it.each([
        [20, 'good'],
        [19.5, 'good'],
        [19, 'good'],
        [18.99, 'warn'],
        [16, 'warn'],
        [15, 'warn'],
        [14.99, 'bad'],
        [10, 'bad'],
        [0, 'bad'],
        [null, 'unknown'],
    ] as const)('puts %s in %s (AC-MS12)', (tps, level) => {
        expect(tpsLevel(tps)).toBe(level);
    });

    it('says each level in words, so colour is never the only signal', () => {
        expect(LEVEL_TEXT).toEqual({ good: 'Healthy', warn: 'Lagging', bad: 'Struggling', unknown: 'N/A' });
    });
});

describe('formatUptime', () => {
    it.each([
        [null, 'N/A'],
        [0, '0s'],
        [45, '45s'],
        [60, '1m'],
        [3599, '59m'],
        [3600, '1h 0m'],
        [5400, '1h 30m'],
        [86399, '23h 59m'],
        [86400, '1d 0h'],
        [90000, '1d 1h'],
        [1_000_000, '11d 13h'],
    ])('writes %s seconds as %s', (seconds, text) => {
        expect(formatUptime(seconds)).toBe(text);
    });
});

describe('numbers', () => {
    it('writes TPS with two decimals and a missing one as N/A (FR-MS10)', () => {
        expect(formatTps(19.98)).toBe('19.98');
        expect(formatTps(20)).toBe('20.00');
        expect(formatTps(null)).toBe('N/A');
    });

    it('writes MSPT in milliseconds without trailing zeros, and a missing one as N/A', () => {
        expect(formatMspt(1.2)).toBe('1.2 ms');
        expect(formatMspt(12)).toBe('12 ms');
        expect(formatMspt(null)).toBe('N/A');
    });
});
