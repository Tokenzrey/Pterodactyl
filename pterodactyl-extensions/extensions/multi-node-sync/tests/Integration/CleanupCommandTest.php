<?php

declare(strict_types=1);

use Illuminate\Support\Facades\File;
use MultiNodeSync\Console\CleanupCommand;
use MultiNodeSync\Tests\ExtensionTestCase;

uses(ExtensionTestCase::class);

it('deletes temporary files older than 4 hours', function (): void {
    $tmpDir = storage_path('app/extensions/multi-node-sync/tmp');
    File::ensureDirectoryExists($tmpDir);

    $oldFile = $tmpDir.'/old-backup.tar.gz';
    $newFile = $tmpDir.'/recent-backup.tar.gz';

    file_put_contents($oldFile, 'old content');
    file_put_contents($newFile, 'recent content');

    touch($oldFile, time() - 5 * 3600);
    touch($newFile, time() - 1 * 3600);

    $this->artisan('multi-node-sync:cleanup')
        ->assertSuccessful()
        ->expectsOutputToContain('Deleted 1 old file(s).');

    expect(file_exists($oldFile))->toBeFalse()
        ->and(file_exists($newFile))->toBeTrue();

    File::deleteDirectory($tmpDir);
});

it('handles a non-existent tmp directory gracefully', function (): void {
    $tmpDir = storage_path('app/extensions/multi-node-sync/tmp');
    if (is_dir($tmpDir)) {
        File::deleteDirectory($tmpDir);
    }

    $this->artisan('multi-node-sync:cleanup')
        ->assertSuccessful()
        ->expectsOutputToContain('Deleted 0 old file(s).');
});

it('cleans up empty subdirectories', function (): void {
    $tmpDir = storage_path('app/extensions/multi-node-sync/tmp');
    File::ensureDirectoryExists($tmpDir.'/old-subdir');

    $oldFile = $tmpDir.'/old-subdir/old-file.tar.gz';
    file_put_contents($oldFile, 'old content');
    touch($oldFile, time() - 5 * 3600);

    $this->artisan('multi-node-sync:cleanup')->assertSuccessful();

    expect(file_exists($oldFile))->toBeFalse()
        ->and(is_dir($tmpDir.'/old-subdir'))->toBeFalse();

    File::deleteDirectory($tmpDir);
});
