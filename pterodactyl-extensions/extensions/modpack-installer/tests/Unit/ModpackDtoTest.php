<?php

declare(strict_types=1);

use ModpackInstaller\Support\ModpackFile;
use ModpackInstaller\Support\ModpackPage;
use ModpackInstaller\Support\ModpackResult;
use ModpackInstaller\Support\ModpackSource;
use ModpackInstaller\Support\ResolvedFile;

it('holds a file a search result offers, and carries no download address', function (): void {
    $file = new ModpackFile('4002', 'atm9.zip', '1.20.1', 'forge', true, 250.5);

    expect($file->fileId)->toBe('4002')
        ->and($file->isServerPack)->toBeTrue()
        ->and($file->fileSizeMb)->toBe(250.5)
        ->and((new ReflectionClass(ModpackFile::class))->hasProperty('downloadUrl'))->toBeFalse();
});

it('cannot be changed once built', function (object $value, string $property): void {
    expect(fn () => $value->{$property} = 'changed')->toThrow(Error::class);
})->with([
    'file' => [new ModpackFile('1', 'a.zip', null, null, false, null), 'name'],
    'result' => [new ModpackResult(ModpackSource::Modrinth, 'AANobbMI', 'A', '', 0, null, []), 'name'],
    'page' => [new ModpackPage([], 0), 'total'],
    'resolved file' => [new ResolvedFile('1', 'a.zip', true, null, null, null), 'name'],
]);

it('holds a search result with its files', function (): void {
    $file = new ModpackFile('1', 'a.zip', null, null, false, null);
    $result = new ModpackResult(ModpackSource::CurseForge, '123', 'ATM', 'All', 10, null, [$file]);

    expect($result->latestFiles)->toBe([$file])
        ->and($result->iconUrl)->toBeNull();
});

it('holds a resolved file, whose address may be missing', function (): void {
    $file = new ResolvedFile('4002', 'a.zip', true, null, 10, null);

    expect($file->downloadUrl)->toBeNull()
        ->and($file->sizeBytes)->toBe(10);
});
