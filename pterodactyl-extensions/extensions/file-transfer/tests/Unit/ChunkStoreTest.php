<?php

declare(strict_types=1);

use FileTransfer\Support\ChunkStore;

const FT_ID = '550e8400-e29b-41d4-a716-446655440000';
const FT_OTHER_ID = '6ba7b810-9dad-41d1-80b4-00c04fd430c8';
const FT_SERVER = '11111111-2222-4333-8444-555555555555';

/** A store over a fresh directory that the test removes itself. */
function ftStore(): ChunkStore
{
    $root = sys_get_temp_dir().'/ft-store-'.bin2hex(random_bytes(6));
    mkdir($root);
    register_shutdown_function(static function () use ($root): void {
        foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST) as $item) {
            $item->isDir() ? @rmdir($item->getPathname()) : @unlink($item->getPathname());
        }
        @rmdir($root);
    });

    return new ChunkStore($root);
}

/** The directory a store works in, so a test can age files inside it. */
function ftRoot(ChunkStore $store): string
{
    return (new ReflectionProperty($store, 'root'))->getValue($store);
}

it('merges chunks in index order whatever order they arrived in (EC-FT1)', function (): void {
    $store = ftStore();
    $store->store(FT_ID, 2, 'CCC');
    $store->store(FT_ID, 0, 'AAA');
    $store->store(FT_ID, 1, 'BBB');

    $store->mergeTo(FT_ID, 3, $store->mergedPath(FT_ID, 'out.zip'));

    expect(file_get_contents($store->mergedPath(FT_ID, 'out.zip')))->toBe('AAABBBCCC');
});

it('lets a repeated chunk replace the first (EC-FT2)', function (): void {
    $store = ftStore();
    $store->store(FT_ID, 0, 'old');
    $store->store(FT_ID, 0, 'new');

    $store->mergeTo(FT_ID, 1, $store->mergedPath(FT_ID, 'out.bin'));

    expect(file_get_contents($store->mergedPath(FT_ID, 'out.bin')))->toBe('new');
});

it('reports which chunks are missing (AC-FT3)', function (): void {
    $store = ftStore();
    $store->store(FT_ID, 0, 'AAA');
    $store->store(FT_ID, 2, 'CCC');

    expect($store->missing(FT_ID, 4))->toBe([1, 3]);
});

it('reports nothing missing once every chunk is there', function (): void {
    $store = ftStore();
    $store->store(FT_ID, 0, 'A');
    $store->store(FT_ID, 1, 'B');

    expect($store->missing(FT_ID, 2))->toBe([]);
});

it('adds up the bytes received, so the size is known before anything is merged (FR-FT6)', function (): void {
    $store = ftStore();
    $store->store(FT_ID, 0, str_repeat('a', 10));
    $store->store(FT_ID, 1, str_repeat('b', 5));

    expect($store->receivedBytes(FT_ID, 3))->toBe(15);
});

it('accepts an empty chunk, and a merge of it is an empty file (EC-FT12)', function (): void {
    $store = ftStore();
    $store->store(FT_ID, 0, '');

    $store->mergeTo(FT_ID, 1, $store->mergedPath(FT_ID, 'empty.txt'));

    expect($store->missing(FT_ID, 1))->toBe([])
        ->and(file_get_contents($store->mergedPath(FT_ID, 'empty.txt')))->toBe('');
});

it('refuses to merge with a chunk missing, and leaves no half file behind (EC-FT4)', function (): void {
    $store = ftStore();
    $store->store(FT_ID, 0, 'AAA');
    $out = $store->mergedPath(FT_ID, 'out.zip');

    expect(fn () => $store->mergeTo(FT_ID, 2, $out))->toThrow(RuntimeException::class)
        ->and(file_exists($out))->toBeFalse();
});

it('deletes every chunk and the record of an upload', function (): void {
    $store = ftStore();
    $store->claim(FT_ID, FT_SERVER, 'a.zip', 2);
    $store->store(FT_ID, 0, 'AAA');

    $store->delete(FT_ID);

    expect($store->missing(FT_ID, 1))->toBe([0])
        ->and($store->meta(FT_ID))->toBeNull();
});

it('does not touch another upload when one is deleted', function (): void {
    $store = ftStore();
    $store->store(FT_ID, 0, 'AAA');
    $store->store(FT_OTHER_ID, 0, 'BBB');

    $store->delete(FT_ID);

    expect($store->missing(FT_OTHER_ID, 1))->toBe([]);
});

describe('claiming an upload id', function (): void {
    it('lets the same server, file and total continue the upload', function (): void {
        $store = ftStore();

        expect($store->claim(FT_ID, FT_SERVER, 'a.zip', 3))->toBeNull()
            ->and($store->claim(FT_ID, FT_SERVER, 'a.zip', 3))->toBeNull()
            ->and($store->meta(FT_ID))->toBe(['server' => FT_SERVER, 'filename' => 'a.zip', 'total_chunks' => 3]);
    });

    it('is a conflict for a different file name (EC-FT3, NFR-FT10)', function (): void {
        $store = ftStore();
        $store->claim(FT_ID, FT_SERVER, 'first.zip', 3);

        expect($store->claim(FT_ID, FT_SERVER, 'second.zip', 3))->toBe('upload_id_conflict');
    });

    it('is a conflict for a different total, so the size cannot be changed half way', function (): void {
        $store = ftStore();
        $store->claim(FT_ID, FT_SERVER, 'a.zip', 3);

        expect($store->claim(FT_ID, FT_SERVER, 'a.zip', 4))->toBe('upload_id_conflict');
    });

    it('is a conflict for another server, so an id cannot be used to write into someone else\'s upload', function (): void {
        $store = ftStore();
        $store->claim(FT_ID, FT_SERVER, 'a.zip', 3);

        expect($store->claim(FT_ID, '99999999-2222-4333-8444-555555555555', 'a.zip', 3))->toBe('upload_id_conflict');
    });

    it('has no record for an upload that was never started', function (): void {
        expect(ftStore()->meta(FT_ID))->toBeNull();
    });
});

describe('ids that are not UUIDs (T-FT3)', function (): void {
    it('never become part of a path', function (string $id): void {
        $store = ftStore();

        expect(fn () => $store->store($id, 0, 'x'))->toThrow(InvalidArgumentException::class)
            ->and(fn () => $store->delete($id))->toThrow(InvalidArgumentException::class)
            ->and(fn () => $store->missing($id, 1))->toThrow(InvalidArgumentException::class)
            ->and(fn () => $store->claim($id, FT_SERVER, 'a.zip', 1))->toThrow(InvalidArgumentException::class)
            ->and(fn () => $store->tmpDir($id))->toThrow(InvalidArgumentException::class);
    })->with(['../../..', '..', '', 'a/b', FT_ID.'/../x', "550e8400-e29b-41d4-a716-446655440000\n"]);

    it('and a file name that is not safe cannot name the merged file', function (): void {
        expect(fn () => ftStore()->mergedPath(FT_ID, '../../x'))->toThrow(InvalidArgumentException::class);
    });
});

describe('purge (FR-FT17, NFR-FT5)', function (): void {
    it('removes uploads whose newest file is older than the age and keeps newer ones (AC-FT17)', function (): void {
        $store = ftStore();
        $store->store(FT_ID, 0, 'old');
        $store->store(FT_OTHER_ID, 0, 'new');
        // Age the first upload: both its directory and its file.
        $root = ftRoot($store);
        touch("{$root}/chunks/".FT_ID.'/0', time() - 3 * 3600);
        touch("{$root}/chunks/".FT_ID, time() - 3 * 3600);

        $removed = $store->purge(2 * 3600, time());

        expect($removed)->toBe(1)
            ->and($store->missing(FT_ID, 1))->toBe([0])
            ->and($store->missing(FT_OTHER_ID, 1))->toBe([]);
    });

    it('keeps an upload that is still being written even when its first chunk is old', function (): void {
        $store = ftStore();
        $store->store(FT_ID, 0, 'first');
        $store->store(FT_ID, 1, 'second');
        touch(ftRoot($store).'/chunks/'.FT_ID.'/0', time() - 5 * 3600);

        expect($store->purge(2 * 3600, time()))->toBe(0)
            ->and($store->missing(FT_ID, 2))->toBe([]);
    });

    it('also removes old merged files and downloads, and files that start with a dot', function (): void {
        $store = ftStore();
        $root = ftRoot($store);
        $store->claim(FT_ID, FT_SERVER, 'a.zip', 1);
        mkdir("{$root}/merged/".FT_ID, 0700, true);
        file_put_contents("{$root}/merged/".FT_ID.'/a.zip', 'x');
        mkdir($store->tmpDir(FT_OTHER_ID), 0700, true);
        file_put_contents($store->tmpDir(FT_OTHER_ID).'/b.zip', 'y');
        foreach (["{$root}/chunks/".FT_ID.'/meta.json', "{$root}/chunks/".FT_ID, "{$root}/merged/".FT_ID.'/a.zip', "{$root}/merged/".FT_ID, $store->tmpDir(FT_OTHER_ID).'/b.zip', $store->tmpDir(FT_OTHER_ID)] as $path) {
            touch($path, time() - 5 * 3600);
        }

        expect($store->purge(2 * 3600, time()))->toBe(3)
            ->and(is_dir("{$root}/chunks/".FT_ID))->toBeFalse()
            ->and(is_dir("{$root}/merged/".FT_ID))->toBeFalse()
            ->and(is_dir($store->tmpDir(FT_OTHER_ID)))->toBeFalse();
    });

    it('does nothing when there is nothing to remove', function (): void {
        expect(ftStore()->purge(3600, time()))->toBe(0);
    });
});
