// SHA-256 that can be fed a file piece by piece. The browser's crypto.subtle can only hash a whole buffer at once, and
// the checksum of a file of up to 10 GB has to be made without ever holding the file in memory (FR-FT4, NFR-FT3).

const K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

const INITIAL = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];

const rotateRight = (value: number, bits: number): number => (value >>> bits) | (value << (32 - bits));

export class Sha256 {
    private readonly state = Uint32Array.from(INITIAL);
    private readonly block = new Uint8Array(64);
    private readonly words = new Uint32Array(64);
    private filled = 0;
    private length = 0;
    private finished = false;

    update(data: Uint8Array): this {
        if (this.finished) {
            throw new Error('The hash is already finished.');
        }

        this.length += data.length;
        let offset = 0;

        if (this.filled > 0) {
            const take = Math.min(64 - this.filled, data.length);
            this.block.set(data.subarray(0, take), this.filled);
            this.filled += take;
            offset = take;
            if (this.filled === 64) {
                this.compress(this.block, 0);
                this.filled = 0;
            }
        }

        for (; offset + 64 <= data.length; offset += 64) {
            this.compress(data, offset);
        }

        if (offset < data.length) {
            this.block.set(data.subarray(offset), 0);
            this.filled = data.length - offset;
        }

        return this;
    }

    /** The digest as 64 lower-case hex digits. The hash cannot be updated afterwards. */
    hex(): string {
        const bits = this.length * 8;
        const padding = (this.filled < 56 ? 56 : 120) - this.filled;
        const tail = new Uint8Array(padding + 8);
        tail[0] = 0x80;
        const view = new DataView(tail.buffer);
        view.setUint32(padding, Math.floor(bits / 0x100000000));
        view.setUint32(padding + 4, bits >>> 0);

        this.update(tail);
        this.finished = true;

        return Array.from(this.state, (word) => word.toString(16).padStart(8, '0')).join('');
    }

    private compress(bytes: Uint8Array, offset: number): void {
        const w = this.words;
        for (let i = 0; i < 16; i++) {
            const j = offset + i * 4;
            w[i] = (bytes[j] << 24) | (bytes[j + 1] << 16) | (bytes[j + 2] << 8) | bytes[j + 3];
        }
        for (let i = 16; i < 64; i++) {
            const a = w[i - 15];
            const b = w[i - 2];
            w[i] = w[i - 16] + (rotateRight(a, 7) ^ rotateRight(a, 18) ^ (a >>> 3)) + w[i - 7] + (rotateRight(b, 17) ^ rotateRight(b, 19) ^ (b >>> 10));
        }

        let [a, b, c, d, e, f, g, h] = this.state;
        for (let i = 0; i < 64; i++) {
            const t1 = (h + (rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) >>> 0;
            const t2 = ((rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
            h = g;
            g = f;
            f = e;
            e = (d + t1) >>> 0;
            d = c;
            c = b;
            b = a;
            a = (t1 + t2) >>> 0;
        }

        const s = this.state;
        s[0] += a;
        s[1] += b;
        s[2] += c;
        s[3] += d;
        s[4] += e;
        s[5] += f;
        s[6] += g;
        s[7] += h;
    }
}

export function sha256Hex(data: Uint8Array): string {
    return new Sha256().update(data).hex();
}
