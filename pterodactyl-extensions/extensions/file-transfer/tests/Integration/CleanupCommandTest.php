<?php

declare(strict_types=1);

use FileTransfer\Support\ChunkStore;
use FileTransfer\Tests\ExtensionTestCase;
use FileTransfer\Tests\Uploads;

uses(ExtensionTestCase::class);

/** Makes an upload on disk and ages everything in it by $hours. */
function ftAged(ExtensionTestCase $case, string $id, int $hours): void
{
    $store = app(ChunkStore::class);
    $store->claim($id, '11111111-2222-4333-8444-555555555555', 'a.zip', 2);
    $store->store($id, 0, 'AAA');
    $store->store($id, 1, 'BBB');

    $dir = $case->storeRoot.'/chunks/'.$id;
    foreach ([...glob("{$dir}/*"), ...glob("{$dir}/.*", GLOB_NOSORT), $dir] as $path) {
        if (basename($path) !== '.' && basename($path) !== '..') {
            touch($path, time() - $hours * 3600);
        }
    }
}

test('uploads older than two hours are deleted and newer ones are kept (AC-FT17, FR-FT17)', function (): void {
    ftAged($this, Uploads::ID, 3);
    ftAged($this, Uploads::OTHER_ID, 1);

    $this->artisan('file-transfer:cleanup')->expectsOutput('Deleted 3 old file(s).')->assertExitCode(0);

    expect(is_dir($this->storeRoot.'/chunks/'.Uploads::ID))->toBeFalse()
        ->and(app(ChunkStore::class)->missing(Uploads::OTHER_ID, 2))->toBe([]);
});

test('the age is the setting, not a fixed two hours', function (): void {
    ftAged($this, Uploads::ID, 3);
    $this->configure(['cleanup_chunk_age_hours' => 5]);

    $this->artisan('file-transfer:cleanup')->expectsOutput('Deleted 0 old file(s).')->assertExitCode(0);

    expect(is_dir($this->storeRoot.'/chunks/'.Uploads::ID))->toBeTrue();
});

test('an old merged file and an old download are deleted too (NFR-FT5, EC-FT5)', function (): void {
    $store = app(ChunkStore::class);
    $merged = $store->mergedPath(Uploads::ID, 'a.zip');
    $store->store(Uploads::OTHER_ID, 0, 'x');
    mkdir(dirname($merged), 0700, true);
    file_put_contents($merged, 'merged');
    $tmp = $store->tmpDir('99999999-2222-4333-8444-555555555555');
    mkdir($tmp, 0700, true);
    file_put_contents("{$tmp}/b.zip", 'downloaded');
    foreach ([$merged, dirname($merged), "{$tmp}/b.zip", $tmp] as $path) {
        touch($path, time() - 5 * 3600);
    }

    $this->artisan('file-transfer:cleanup')->expectsOutput('Deleted 2 old file(s).')->assertExitCode(0);

    expect(is_dir(dirname($merged)))->toBeFalse()
        ->and(is_dir($tmp))->toBeFalse()
        ->and(app(ChunkStore::class)->missing(Uploads::OTHER_ID, 1))->toBe([]);
});

test('it runs when there is nothing on disk at all', function (): void {
    $this->artisan('file-transfer:cleanup')->expectsOutput('Deleted 0 old file(s).')->assertExitCode(0);
});
