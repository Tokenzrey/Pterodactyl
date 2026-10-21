import { describe, expect, it } from 'vitest';
import { parseConfig } from './config';

describe('parseConfig', () => {
    it('reads the two public settings', () => {
        expect(parseConfig({ chunk_size_mb: 8, max_file_mb: 4096 })).toEqual({ chunkSizeMb: 8, maxFileMb: 4096 });
    });

    it('uses 5 MB pieces and a 2048 MB limit when the settings are absent', () => {
        expect(parseConfig({})).toEqual({ chunkSizeMb: 5, maxFileMb: 2048 });
    });

    it.each([
        ['zero', 0],
        ['negative', -1],
        ['above the range', 11],
        ['fractional', 2.5],
        ['text', '5'],
        ['null', null],
        ['NaN', Number.NaN],
    ])('falls back to the default for a piece size that is %s', (_label, value) => {
        expect(parseConfig({ chunk_size_mb: value as never }).chunkSizeMb).toBe(5);
    });

    it.each([0, 10241, 1.5, '2048', null])('falls back to the default for a file limit of %j', (value) => {
        expect(parseConfig({ max_file_mb: value as never }).maxFileMb).toBe(2048);
    });

    it('accepts the edges of both ranges', () => {
        expect(parseConfig({ chunk_size_mb: 1, max_file_mb: 1 })).toEqual({ chunkSizeMb: 1, maxFileMb: 1 });
        expect(parseConfig({ chunk_size_mb: 10, max_file_mb: 10240 })).toEqual({ chunkSizeMb: 10, maxFileMb: 10240 });
    });
});
