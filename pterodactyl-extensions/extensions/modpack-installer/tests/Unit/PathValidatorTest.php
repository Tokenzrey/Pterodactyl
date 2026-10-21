<?php

declare(strict_types=1);

use ModpackInstaller\Support\PathValidator;

// FR-MI5, FR-MI19, NFR-MI9, T-MI3: nothing that could climb out of the server's files gets to Wings.

it('accepts a relative folder, nested folders, and the root', function (string $path): void {
    expect(PathValidator::validate($path))->toBeNull();
})->with(['mods', 'packs/atm9', 'a-b_c.d/e', '.', str_repeat('a', 255)]);

it('refuses a folder that is empty, absolute, climbing, or made of odd characters', function (string $path): void {
    expect(PathValidator::validate($path))->toBe('invalid_target_directory');
})->with([
    'empty' => '',
    'root slash' => '/',
    'absolute' => '/etc/passwd',
    'dot dot' => '..',
    'leading dot dot' => '../etc',
    'middle dot dot' => 'a/../b',
    'dot dot in a name' => 'a..b',
    'double slash' => 'a//b',
    'space' => 'my mods',
    'semicolon' => 'a;b',
    'backslash' => 'a\\b',
    'unicode' => 'café',
    'null byte' => "a\0b",
    'trailing newline' => "mods\n",
    'newline in the middle' => "a\nb",
    'too long' => str_repeat('a', 256),
]);

it('builds the path of a file inside a folder', function (string $directory, string $expected): void {
    expect(PathValidator::join($directory, 'modpack.zip'))->toBe($expected);
})->with([
    'root' => ['.', '/modpack.zip'],
    'folder' => ['packs', '/packs/modpack.zip'],
    'nested' => ['packs/atm9', '/packs/atm9/modpack.zip'],
    'trailing slash' => ['packs/', '/packs/modpack.zip'],
    'dot segment' => ['./packs', '/packs/modpack.zip'],
]);

it('builds the path of a folder', function (string $directory, string $expected): void {
    expect(PathValidator::absolute($directory))->toBe($expected);
})->with([
    'root' => ['.', '/'],
    'folder' => ['packs', '/packs'],
    'nested' => ['packs/atm9', '/packs/atm9'],
]);
