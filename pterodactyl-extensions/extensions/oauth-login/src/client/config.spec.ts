import { describe, expect, it } from 'vitest';
import { parseConfig } from './config';

describe('parseConfig', () => {
    it('keeps the known providers in a fixed order, whatever order they were enabled in', () => {
        expect(parseConfig({ enabled_providers: ['google', 'discord'] }).providers).toEqual(['discord', 'google']);
        expect(parseConfig({ enabled_providers: ['github', 'google', 'discord'] }).providers).toEqual(['discord', 'github', 'google']);
    });

    it('drops unknown ids and duplicates instead of turning them into links', () => {
        expect(parseConfig({ enabled_providers: ['gitlab', 'discord', 'discord', '../x', 'DISCORD', ''] }).providers).toEqual(['discord']);
    });

    it.each([
        ['missing', {}],
        ['null', { enabled_providers: null }],
        ['a string', { enabled_providers: 'discord' }],
        ['an object', { enabled_providers: { 0: 'discord' } }],
        ['a number', { enabled_providers: 1 }],
        ['an empty list', { enabled_providers: [] }],
        ['a list of non-strings', { enabled_providers: [1, null, true, ['discord']] }],
    ])('yields no providers when enabled_providers is %s', (_label, config) => {
        expect(parseConfig(config).providers).toEqual([]);
    });
});
