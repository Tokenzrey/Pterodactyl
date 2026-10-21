<?php

declare(strict_types=1);

use ModpackInstaller\Support\ModpackSearchCache;
use ModpackInstaller\Support\ModpackSource;

// FR-MI3: a key for the source, query and filters, and for the page as well, or page two would answer with page one.

$base = [ModpackSource::CurseForge, 'jei', '1.20.1', 'forge', 0];

it('is the same for the same search', function () use ($base): void {
    expect(ModpackSearchCache::key(...$base))->toBe(ModpackSearchCache::key(...$base));
});

it('differs when anything about the search differs', function (int $index, mixed $value) use ($base): void {
    $other = $base;
    $other[$index] = $value;

    expect(ModpackSearchCache::key(...$other))->not->toBe(ModpackSearchCache::key(...$base));
})->with([
    'source' => [0, ModpackSource::Modrinth],
    'query' => [1, 'jei2'],
    'game version' => [2, '1.19.2'],
    'no game version' => [2, null],
    'loader' => [3, 'fabric'],
    'no loader' => [3, null],
    'page' => [4, 1],
]);

it('does not mix an empty filter with a missing one, or one field with another', function (): void {
    expect(ModpackSearchCache::key(ModpackSource::CurseForge, 'a', null, null, 0))->not->toBe(ModpackSearchCache::key(ModpackSource::CurseForge, 'a', '', null, 0))
        ->and(ModpackSearchCache::key(ModpackSource::CurseForge, 'ab', null, null, 0))->not->toBe(ModpackSearchCache::key(ModpackSource::CurseForge, 'a', 'b', null, 0));
});

it('is a plain key whatever a person types', function (string $query): void {
    expect(ModpackSearchCache::key(ModpackSource::Modrinth, $query, null, null, 0))->toMatch('/\Amodpack-installer:search:[0-9a-f]{64}\z/');
})->with(['spaces here', "line\nbreak", 'ünïcode ✓', str_repeat('x', 100), "{braces}:colons:"]);
