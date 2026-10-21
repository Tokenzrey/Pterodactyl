<?php

declare(strict_types=1);

use MultiNodeSync\Support\PathValidator;

it('accepts a valid relative path', function (): void {
    expect(PathValidator::validate('backups/server1.zip'))->toBeNull();
});

it('rejects an empty path', function (): void {
    expect(PathValidator::validate(''))->toBe('invalid_path');
});

it('rejects a path containing double dots', function (): void {
    expect(PathValidator::validate('../etc/passwd'))->toBe('invalid_path')
        ->and(PathValidator::validate('foo/../bar'))->toBe('invalid_path')
        ->and(PathValidator::validate('backups/../../etc/passwd'))->toBe('invalid_path');
});

it('rejects an absolute path', function (): void {
    expect(PathValidator::validate('/etc/passwd'))->toBe('invalid_path')
        ->and(PathValidator::validate('/backups/test.zip'))->toBe('invalid_path');
});

it('rejects paths with invalid characters', function (): void {
    expect(PathValidator::validate('backups/file name.zip'))->toBe('invalid_path')
        ->and(PathValidator::validate('backups/file;name.zip'))->toBe('invalid_path')
        ->and(PathValidator::validate('backups/file|name.zip'))->toBe('invalid_path')
        ->and(PathValidator::validate('backups/file$name.zip'))->toBe('invalid_path');
});

it('accepts paths with valid characters', function (): void {
    expect(PathValidator::validate('migrations/server-1/backup_2026.zip'))->toBeNull()
        ->and(PathValidator::validate('a-b_c.d/e.zip'))->toBeNull();
});

it('rejects paths exceeding the max length', function (): void {
    $long = str_repeat('a', 256);
    expect(PathValidator::validate($long, 255))->toBe('invalid_path');
});

it('accepts object keys up to 1024 characters', function (): void {
    $key = str_repeat('a', 1024);
    expect(PathValidator::validate($key, 1024))->toBeNull()
        ->and(PathValidator::validate(str_repeat('a', 1025), 1024))->toBe('invalid_path');
});

it('accepts target directories up to 255 characters', function (): void {
    $dir = str_repeat('a', 255);
    expect(PathValidator::validate($dir, 255))->toBeNull();
});

it('rejects a trailing newline, which "$" would let through', function (): void {
    expect(PathValidator::validate("backups/server1.zip\n"))->toBe('invalid_path')
        ->and(PathValidator::validate("backups\n/x"))->toBe('invalid_path')
        ->and(PathValidator::validate("a\r"))->toBe('invalid_path');
});

it('rejects empty and dot segments, which a proxy may fold away and so change what was signed', function (): void {
    expect(PathValidator::validate('a//b'))->toBe('invalid_path')
        ->and(PathValidator::validate('a/./b'))->toBe('invalid_path')
        ->and(PathValidator::validate('./a'))->toBe('invalid_path')
        ->and(PathValidator::validate('.'))->toBe('invalid_path')
        ->and(PathValidator::validate('a/'))->toBe('invalid_path');
});

it('accepts dots inside a name', function (): void {
    expect(PathValidator::validate('.hidden/file.tar.gz'))->toBeNull()
        ->and(PathValidator::validate('v1.2.3/a.b'))->toBeNull();
});

it('rejects non-ASCII letters, backslashes and control characters', function (): void {
    expect(PathValidator::validate('café/x'))->toBe('invalid_path')
        ->and(PathValidator::validate('a\b'))->toBe('invalid_path')
        ->and(PathValidator::validate("a\0b"))->toBe('invalid_path')
        ->and(PathValidator::validate("a\tb"))->toBe('invalid_path');
});
