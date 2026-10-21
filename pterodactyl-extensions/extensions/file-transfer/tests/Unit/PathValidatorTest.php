<?php

declare(strict_types=1);

use FileTransfer\Support\PathValidator;

it('accepts a relative path and the server root', function (string $path): void {
    expect(PathValidator::validate($path))->toBeNull();
})->with(['mods', 'sub/dir', 'plugins/Essentials/', '.', 'a.b/c-d_e']);

it('rejects anything that could leave the server files (AC-FT19, NFR-FT7)', function (string $path): void {
    expect(PathValidator::validate($path))->toBe('invalid_target_directory');
})->with([
    'parent directories' => ['../../../'],
    'one parent' => ['..'],
    'a parent in the middle' => ['a/../b'],
    'a hidden parent' => ['a/..b'],
    'absolute' => ['/etc/passwd'],
    'the root as an absolute path' => ['/'],
    'a double slash' => ['a//b'],
    'a backslash' => ['a\\b'],
    'a shell character' => ['mods;rm -rf /'],
    'a space' => ['my mods'],
    'a null byte' => ["mods\0"],
    'a trailing newline' => ["mods\n"],
    'too long' => [str_repeat('a', 256)],
    'empty' => [''],
]);

it('accepts exactly 255 characters', function (): void {
    expect(PathValidator::validate(str_repeat('a', 255)))->toBeNull();
});

it('joins a directory and a file name into a path on the server', function (string $directory, string $expected): void {
    expect(PathValidator::join($directory, 'pack.zip'))->toBe($expected);
})->with([
    'a folder' => ['mods', '/mods/pack.zip'],
    'a nested folder' => ['a/b', '/a/b/pack.zip'],
    'the root' => ['.', '/pack.zip'],
    'a trailing slash' => ['mods/', '/mods/pack.zip'],
    'a leading dot segment' => ['./mods', '/mods/pack.zip'],
]);
