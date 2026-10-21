import { describe, expect, it } from 'vitest';
import { displayDirectory, formatBytes, isFetchableUrl, isValidFileName, relativeDirectory, suggestFileName } from './paths';

// The backend's PathValidator and ChunkValidator refuse anything these helpers let through; the screen must agree with them.

describe('relativeDirectory', () => {
    it.each([
        ['/', '.'],
        ['', '.'],
        ['.', '.'],
        ['/plugins', 'plugins'],
        ['/plugins/Essentials/', 'plugins/Essentials'],
        ['plugins//Essentials', 'plugins/Essentials'],
        ['/./plugins', 'plugins'],
    ])('turns %j into %j', (directory, expected) => {
        expect(relativeDirectory(directory)).toBe(expected);
    });

    it('never starts with a slash, which the backend refuses', () => {
        expect(relativeDirectory('///a///b///').startsWith('/')).toBe(false);
    });
});

describe('displayDirectory', () => {
    it.each([
        ['/', '/'],
        ['/plugins/Essentials', '/plugins/Essentials'],
        ['plugins', '/plugins'],
    ])('shows %j as %j', (directory, expected) => {
        expect(displayDirectory(directory)).toBe(expected);
    });
});

describe('isValidFileName', () => {
    it.each(['world.zip', 'a', 'my-file_1.tar.gz', '.env', 'a'.repeat(255)])('accepts %j', (name) => {
        expect(isValidFileName(name)).toBe(true);
    });

    it.each(['', '.', '..', '...', 'a/b', 'a b', 'ü.txt', 'a\nb', 'a'.repeat(256), 'a\\b'])('refuses %j', (name) => {
        expect(isValidFileName(name)).toBe(false);
    });
});

describe('suggestFileName', () => {
    it.each([
        ['world.zip', 'world.zip'],
        ['My World (1).zip', 'My_World__1_.zip'],
        ['ü.txt', '_.txt'],
        ['..', ''],
        ['', ''],
    ])('makes %j into %j', (name, expected) => {
        expect(suggestFileName(name)).toBe(expected);
    });

    it('always gives a name isValidFileName accepts, or nothing', () => {
        for (const name of ['a/b', 'x'.repeat(400), '…', 'tab\there']) {
            const suggestion = suggestFileName(name);

            expect(suggestion === '' || isValidFileName(suggestion)).toBe(true);
        }
    });
});

describe('isFetchableUrl', () => {
    it.each(['https://example.com/a.zip', 'http://example.com:8080/a?x=1', 'https://203.0.113.5/a'])('accepts %j', (value) => {
        expect(isFetchableUrl(value)).toBe(true);
    });

    it.each(['', 'example.com/a.zip', 'ftp://example.com/a', 'file:///etc/passwd', 'javascript:alert(1)', 'https://user:pw@example.com/a', 'https://user@example.com/a', 'https://'])('refuses %j', (value) => {
        expect(isFetchableUrl(value)).toBe(false);
    });
});

describe('formatBytes', () => {
    it.each([
        [0, '0 B'],
        [1023, '1023 B'],
        [1024, '1 KB'],
        [1536, '1.5 KB'],
        [5 * 1024 * 1024, '5 MB'],
        [150 * 1024 * 1024, '150 MB'],
        [2 * 1024 ** 3, '2 GB'],
        [3 * 1024 ** 4, '3 TB'],
        [5000 * 1024 ** 4, '5000 TB'],
    ])('writes %i bytes as %s', (bytes, expected) => {
        expect(formatBytes(bytes)).toBe(expected);
    });
});
