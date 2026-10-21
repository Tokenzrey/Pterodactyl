import { describe, expect, it } from 'vitest';
import { CRAFATAR_BASE, crafatarUrl } from './crafatar';

// FR-MS11, FR-MS12, NFR-MS5, T-MS6: the base URL is a constant and a UUID is checked before it is put in a URL.

const UUID = '069a79f4-44e9-4726-a5be-fca90e38aaf5';

describe('crafatarUrl', () => {
    it('builds the avatar URL for a valid UUID (AC-MS13)', () => {
        expect(crafatarUrl('avatar', UUID, 64)).toBe(`https://crafatar.com/avatars/${UUID}?size=64`);
    });

    it('leaves the size out when none is asked for', () => {
        expect(crafatarUrl('avatar', UUID)).toBe(`https://crafatar.com/avatars/${UUID}`);
    });

    it.each([
        ['head', `https://crafatar.com/renders/head/${UUID}`],
        ['body', `https://crafatar.com/renders/body/${UUID}`],
        ['cape', `https://crafatar.com/capes/${UUID}`],
    ] as const)('knows the %s path', (type, expected) => {
        expect(crafatarUrl(type, UUID)).toBe(expected);
    });

    it('writes a UUID without hyphens, or in capitals, with hyphens in lower case', () => {
        expect(crafatarUrl('avatar', '069A79F444E94726A5BEFCA90E38AAF5', 32)).toBe(`https://crafatar.com/avatars/${UUID}?size=32`);
    });

    it.each([
        ['null', null],
        ['empty', ''],
        ['a name', 'Steve'],
        ['too short', '069a79f4-44e9-4726-a5be'],
        ['a path', '../../evil'],
        ['a query', `${UUID}?x=1`],
        ['a scheme', 'https://evil.example/x'],
        ['mixed hyphens', '069a79f444e9-4726-a5be-fca90e38aaf5'],
    ])('refuses %s: no URL at all (AC-MS14, T-MS6)', (_label, value) => {
        expect(crafatarUrl('avatar', value, 64)).toBeNull();
    });

    it('keeps the base address a constant', () => {
        expect(CRAFATAR_BASE).toBe('https://crafatar.com/');
    });

    it.each([0, -1, 1.5, 9999])('ignores a size of %s: it is not put in the URL', (size) => {
        expect(crafatarUrl('avatar', UUID, size)).toBe(`https://crafatar.com/avatars/${UUID}`);
    });
});
