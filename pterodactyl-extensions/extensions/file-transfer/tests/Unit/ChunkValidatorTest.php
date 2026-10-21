<?php

declare(strict_types=1);

use FileTransfer\Support\ChunkValidator;

const FT_UPLOAD_ID = '550e8400-e29b-41d4-a716-446655440000';

function ftCheck(string $uploadId = FT_UPLOAD_ID, int $index = 0, int $total = 10, string $filename = 'modpack.zip', ?string $checksum = null): ?string
{
    return ChunkValidator::validate($uploadId, $index, $total, $filename, $checksum ?? hash('sha256', 'test'));
}

it('accepts valid chunk parameters', function (): void {
    expect(ftCheck())->toBeNull();
});

it('accepts the first and the last index', function (int $index): void {
    expect(ftCheck(index: $index))->toBeNull();
})->with([0, 9]);

it('rejects an upload_id that is not a version 4 UUID (FR-FT2)', function (string $id): void {
    expect(ftCheck($id))->toBe('invalid_upload_id');
})->with([
    'not a uuid' => ['not-a-uuid'],
    'empty' => [''],
    'a path' => ['../../../etc/passwd'],
    'version 1' => ['550e8400-e29b-11d4-a716-446655440000'],
    'bad variant' => ['550e8400-e29b-41d4-c716-446655440000'],
    'trailing newline' => ["550e8400-e29b-41d4-a716-446655440000\n"],
]);

it('rejects an index outside 0 to total_chunks-1 (FR-FT2)', function (int $index): void {
    expect(ftCheck(index: $index))->toBe('invalid_chunk_index');
})->with([-1, 10, 11]);

it('rejects a total of zero as an invalid total, not as an invalid index', function (): void {
    expect(ftCheck(index: 0, total: 0))->toBe('invalid_total_chunks');
});

it('rejects a total above 10000 and accepts exactly 10000', function (): void {
    expect(ftCheck(total: 10001))->toBe('invalid_total_chunks')
        ->and(ftCheck(index: 9999, total: 10000))->toBeNull();
});

it('rejects a filename that could reach another path (AC-FT6, T-FT3)', function (string $name): void {
    expect(ftCheck(filename: $name))->toBe('invalid_filename');
})->with([
    'traversal' => ['../../etc/passwd'],
    'a separator' => ['dir/file.zip'],
    'a backslash' => ['dir\\file.zip'],
    'the parent directory' => ['..'],
    'the current directory' => ['.'],
    'dots only' => ['...'],
    'a semicolon' => ['file;rm.zip'],
    'a space' => ['my file.zip'],
    'a null byte' => ["file\0.zip"],
    'a trailing newline' => ["file.zip\n"],
    'too long' => [str_repeat('a', 256)],
    'empty' => [''],
]);

it('accepts names of 1 to 255 safe characters, including hidden files', function (string $name): void {
    expect(ftCheck(filename: $name))->toBeNull();
})->with(['a', 'server.properties', 'my-mod_1.2.3.jar', '.gitignore', 'a..b']);

it('rejects a checksum that is not 64 hex digits', function (string $checksum): void {
    expect(ftCheck(checksum: $checksum))->toBe('invalid_checksum');
})->with([
    'words' => ['not-a-sha256'],
    'too short' => [str_repeat('a', 63)],
    'too long' => [str_repeat('a', 65)],
    'a trailing newline' => [str_repeat('a', 64)."\n"],
]);

it('accepts an upper-case checksum', function (): void {
    expect(ftCheck(checksum: strtoupper(hash('sha256', 'x'))))->toBeNull();
});
