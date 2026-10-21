import { randomBytes } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { toBase64 } from './base64';

describe('toBase64', () => {
    it.each([0, 1, 2, 3, 4, 100, 32767, 32768, 32769, 65536, 1_000_001])('equals the reference for %i random bytes', (size) => {
        const data = new Uint8Array(randomBytes(size));

        expect(toBase64(data)).toBe(Buffer.from(data).toString('base64'));
    });

    it('keeps every byte value, so a binary file is not damaged on the way', () => {
        const data = Uint8Array.from({ length: 256 }, (_, i) => i);

        expect(Buffer.from(toBase64(data), 'base64')).toEqual(Buffer.from(data));
    });

    it('is empty for no data', () => {
        expect(toBase64(new Uint8Array())).toBe('');
    });
});
