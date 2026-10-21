<?php

declare(strict_types=1);

use ModpackInstaller\Support\ModpackSource;

// NFR-MI3: the API addresses are constants in the code, over https, and there is no way to set them.

it('has fixed https addresses for both sources', function (): void {
    expect(ModpackSource::CurseForge->baseUrl())->toBe('https://api.curseforge.com/v1/')
        ->and(ModpackSource::Modrinth->baseUrl())->toBe('https://api.modrinth.com/v2/');
});

it('knows which source needs an API key', function (): void {
    expect(ModpackSource::CurseForge->requiresApiKey())->toBeTrue()
        ->and(ModpackSource::Modrinth->requiresApiKey())->toBeFalse();
});

it('knows that only CurseForge has server packs', function (): void {
    expect(ModpackSource::CurseForge->hasServerPacks())->toBeTrue()
        ->and(ModpackSource::Modrinth->hasServerPacks())->toBeFalse();
});

it('is built from the two values the API accepts, and from nothing else', function (): void {
    expect(ModpackSource::from('curseforge'))->toBe(ModpackSource::CurseForge)
        ->and(ModpackSource::tryFrom('modrinth'))->toBe(ModpackSource::Modrinth)
        ->and(ModpackSource::tryFrom('CurseForge'))->toBeNull()
        ->and(ModpackSource::tryFrom('http://evil.test'))->toBeNull();
});

it('accepts an id of the right shape for its source', function (ModpackSource $source, string $id): void {
    expect(preg_match($source->idPattern(), $id))->toBe(1);
})->with([
    'curseforge short' => [ModpackSource::CurseForge, '1'],
    'curseforge long' => [ModpackSource::CurseForge, '1234567890'],
    'modrinth' => [ModpackSource::Modrinth, 'AANobbMI'],
    'modrinth digits' => [ModpackSource::Modrinth, '12345678'],
]);

it('refuses an id that could change a URL path or carries a line break', function (ModpackSource $source, string $id): void {
    expect(preg_match($source->idPattern(), $id))->toBe(0);
})->with([
    'empty' => [ModpackSource::CurseForge, ''],
    'letters at curseforge' => [ModpackSource::CurseForge, '12a'],
    'eleven digits' => [ModpackSource::CurseForge, '12345678901'],
    'traversal' => [ModpackSource::CurseForge, '../1'],
    'slash' => [ModpackSource::CurseForge, '1/2'],
    'query' => [ModpackSource::CurseForge, '1?x=2'],
    'newline' => [ModpackSource::CurseForge, "12\n"],
    'seven at modrinth' => [ModpackSource::Modrinth, 'AANobbM'],
    'nine at modrinth' => [ModpackSource::Modrinth, 'AANobbMIx'],
    'slash at modrinth' => [ModpackSource::Modrinth, 'AAN/bbMI'],
    'newline at modrinth' => [ModpackSource::Modrinth, "AANobbMI\n"],
]);
