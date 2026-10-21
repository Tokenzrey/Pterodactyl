/** Standard base64 of binary data. Cut into slices because a single String.fromCharCode call cannot take a 10 MB spread. */
export function toBase64(bytes: Uint8Array): string {
    let binary = '';
    for (let offset = 0; offset < bytes.length; offset += 0x8000) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
    }

    return btoa(binary);
}
