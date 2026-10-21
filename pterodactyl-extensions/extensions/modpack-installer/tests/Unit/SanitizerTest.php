<?php

declare(strict_types=1);

use ModpackInstaller\Support\Sanitizer;

// FR-MI9, NFR-MI10, T-MI4, EC-MI11: only fixed names and plain file names ever reach the delete.

it('always removes the five launch scripts', function (): void {
    expect(Sanitizer::files([]))->toBe(['start.sh', 'run.bat', 'user_jvm_args.txt', 'start.bat', 'ServerStart.bat']);
});

it('adds what the admin listed, once', function (): void {
    expect(Sanitizer::files(['custom.sh', 'start.sh', 'custom.sh']))->toBe(['start.sh', 'run.bat', 'user_jvm_args.txt', 'start.bat', 'ServerStart.bat', 'custom.sh']);
});

it('drops an entry that is not a plain file name, so it can never point a delete elsewhere', function (string $entry): void {
    expect(Sanitizer::files([$entry]))->toBe(Sanitizer::SANITIZED_FILES);
})->with([
    'path' => 'config/server.properties',
    'absolute' => '/etc/passwd',
    'traversal' => '../world',
    'dot' => '.',
    'dot dot' => '..',
    'empty' => '',
    'backslash' => 'a\\b',
    'null byte' => "a\0b",
    'newline' => "a\nb",
    'too long' => str_repeat('a', 65),
]);

it('judges a file name', function (string $name, bool $expected): void {
    expect(Sanitizer::isFilenameOnly($name))->toBe($expected);
})->with([
    ['start.sh', true],
    ['.hidden', true],
    [str_repeat('a', 64), true],
    ['dir/file', false],
    ['dir\\file', false],
    ['', false],
    ['..', false],
]);
