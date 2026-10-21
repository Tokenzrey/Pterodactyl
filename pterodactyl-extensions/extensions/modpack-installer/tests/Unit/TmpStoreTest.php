<?php

declare(strict_types=1);

use ModpackInstaller\Support\TmpStore;

const TS_ID = '550e8400-e29b-41d4-a716-446655440000';
const TS_OTHER = '6ba7b810-9dad-41d1-80b4-00c04fd430c8';

function tsRoot(): string
{
    $root = sys_get_temp_dir().'/ts-'.bin2hex(random_bytes(6));
    register_shutdown_function(static function () use ($root): void {
        foreach (glob("{$root}/tmp/*/*") ?: [] as $file) {
            @unlink($file);
        }
        foreach (glob("{$root}/tmp/*") ?: [] as $dir) {
            @rmdir($dir);
        }
        @rmdir("{$root}/tmp");
        @rmdir($root);
    });

    return $root;
}

/** Puts a file in the job's directory and makes everything in it this many seconds old. */
function tsAged(TmpStore $store, string $id, int $seconds): void
{
    $dir = $store->dir($id);
    file_put_contents("{$dir}/modpack.zip", 'x');
    foreach ([$dir, "{$dir}/modpack.zip"] as $path) {
        touch($path, time() - $seconds);
    }
}

it('makes a private directory for a job under its own root', function (): void {
    $root = tsRoot();
    $dir = (new TmpStore($root))->dir(TS_ID);

    expect($dir)->toBe("{$root}/tmp/".TS_ID)
        ->and(is_dir($dir))->toBeTrue()
        ->and(substr(sprintf('%o', fileperms($dir)), -3))->toBe('700');
});

it('gives the same directory again for the same job', function (): void {
    $store = new TmpStore(tsRoot());

    expect($store->dir(TS_ID))->toBe($store->dir(TS_ID));
});

it('takes only a UUID for a job id, so an id can never name a path', function (string $id): void {
    $store = new TmpStore(tsRoot());

    expect(fn () => $store->dir($id))->toThrow(InvalidArgumentException::class)
        ->and(fn () => $store->delete($id))->toThrow(InvalidArgumentException::class);
})->with(['../etc', '..', '', 'abc', '550e8400-e29b-41d4-a716-44665544000/../x', "550e8400-e29b-41d4-a716-446655440000\n", '550e8400/e29b/41d4/a716/446655440000']);

it('deletes a job directory and what is in it', function (): void {
    $store = new TmpStore(tsRoot());
    tsAged($store, TS_ID, 0);
    $dir = $store->dir(TS_ID);

    $store->delete(TS_ID);

    expect(is_dir($dir))->toBeFalse();
});

it('deletes nothing and does not fail when there is no such directory', function (): void {
    $store = new TmpStore(tsRoot());

    $store->delete(TS_ID);

    expect(true)->toBeTrue();
});

it('purges what is older than the age, and keeps what is newer (NFR-MI6, T-MI12)', function (): void {
    $root = tsRoot();
    $store = new TmpStore($root);
    tsAged($store, TS_ID, 3 * 3600);
    tsAged($store, TS_OTHER, 3600);

    $removed = $store->purge(7200, time());

    // dir() would create the directory again, so look at the disk.
    expect($removed)->toBe(1)
        ->and(file_exists("{$root}/tmp/".TS_ID))->toBeFalse()
        ->and(file_exists("{$root}/tmp/".TS_OTHER.'/modpack.zip'))->toBeTrue();
});

it('judges a directory by its newest file, so a download in progress is not purged', function (): void {
    $store = new TmpStore(tsRoot());
    tsAged($store, TS_ID, 3 * 3600);
    touch($store->dir(TS_ID).'/modpack.zip', time());

    expect($store->purge(7200, time()))->toBe(0);
});

it('purges nothing when there is no store yet', function (): void {
    expect((new TmpStore(tsRoot()))->purge(0, time()))->toBe(0);
});
