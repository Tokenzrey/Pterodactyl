import { createHash, randomBytes } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { Sha256, sha256Hex } from './sha256';

// The checksum of a whole file is made piece by piece in the browser. It has to equal what the server computes with
// hash_file('sha256'), for every length and every way of cutting the data into pieces.

const reference = (data: Uint8Array): string => createHash('sha256').update(data).digest('hex');

describe('sha256Hex', () => {
    it.each([
        ['the empty input', '', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'],
        ['"abc"', 'abc', 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'],
        ['the 448-bit test message', 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq', '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1'],
    ])('matches the published vector for %s', (_label, text, expected) => {
        expect(sha256Hex(new TextEncoder().encode(text))).toBe(expected);
    });

    it('matches the one-million-a vector', () => {
        expect(sha256Hex(new Uint8Array(1_000_000).fill(0x61))).toBe('cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
    });

    it.each([0, 1, 2, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 1000, 65535, 65536, 100_003])('equals the reference for %i random bytes', (size) => {
        const data = new Uint8Array(randomBytes(size));

        expect(sha256Hex(data)).toBe(reference(data));
    });

    it('equals the reference for every byte value', () => {
        const data = Uint8Array.from({ length: 256 }, (_, i) => i);

        expect(sha256Hex(data)).toBe(reference(data));
    });
});

describe('feeding the data in pieces', () => {
    it.each([1, 3, 7, 55, 63, 64, 65, 100, 1024, 4999])('gives the same digest when cut into pieces of %i bytes', (piece) => {
        const data = new Uint8Array(randomBytes(5000));
        const hash = new Sha256();
        for (let offset = 0; offset < data.length; offset += piece) {
            hash.update(data.subarray(offset, offset + piece));
        }

        expect(hash.hex()).toBe(reference(data));
    });

    it('gives the same digest when pieces differ in size, including empty ones', () => {
        const data = new Uint8Array(randomBytes(777));
        const hash = new Sha256();
        hash.update(data.subarray(0, 0)).update(data.subarray(0, 10)).update(data.subarray(10, 10)).update(data.subarray(10, 600)).update(data.subarray(600));

        expect(hash.hex()).toBe(reference(data));
    });

    it('keeps the length right past 512 MiB, where the length in bits no longer fits in 32 bits', () => {
        // 520 MiB is 4.36 billion bits: more than 2^32, so the upper half of the 64-bit length is used.
        const block = new Uint8Array(1 << 20).fill(7);
        const hash = new Sha256();
        const reference256 = createHash('sha256');
        for (let i = 0; i < 520; i++) {
            hash.update(block);
            reference256.update(block);
        }

        expect(hash.hex()).toBe(reference256.digest('hex'));
    }, 60_000);
});

describe('a finished hash', () => {
    it('refuses to be updated again, instead of returning a wrong digest', () => {
        const hash = new Sha256().update(new Uint8Array([1, 2, 3]));
        hash.hex();

        expect(() => hash.update(new Uint8Array([4]))).toThrow(/finished/);
    });
});
