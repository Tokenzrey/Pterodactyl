<?php

declare(strict_types=1);

use FileTransfer\Support\ChunkStore;
use FileTransfer\Support\TransferException;
use FileTransfer\Tests\ExtensionTestCase;
use FileTransfer\Tests\Uploads;
use Illuminate\Log\Events\MessageLogged;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Event;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;

uses(ExtensionTestCase::class);

/** Sends every chunk of $whole, cut into pieces of $size bytes, as a user with file.create. Returns that user. */
function ftSend(object $case, Server $server, string $whole, int $size = 4, string $id = Uploads::ID, string $name = 'pack.zip'): User
{
    $user = Uploads::subuser($server, ['file.create']);
    $pieces = $whole === '' ? [''] : str_split($whole, $size);
    foreach ($pieces as $index => $piece) {
        $case->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk($id, $index, count($pieces), $piece, $name))->assertOk();
    }

    return $user;
}

test('the chunks are merged, checked, handed to the server and removed (AC-FT2)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, 'the whole file contents');

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'the whole file contents'))
        ->assertOk()->assertExactJson(['uploaded' => true]);

    expect($this->wings->uploads)->toBe([['server' => $server->uuid, 'path' => '/mods/pack.zip', 'content' => 'the whole file contents']])
        ->and(app(ChunkStore::class)->meta(Uploads::ID))->toBeNull()
        ->and(is_dir($this->storeRoot.'/merged/'.Uploads::ID))->toBeFalse();
});

test('an empty file is uploaded as an empty file (EC-FT12)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, '');

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, ''))->assertOk();

    expect($this->wings->uploads[0]['content'])->toBe('');
});

test('a file for the root of the server goes to /name, and a nested folder keeps its path', function (string $directory, string $path): void {
    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, 'abcd');

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd', $directory))->assertOk();

    expect($this->wings->uploads[0]['path'])->toBe($path);
})->with([['.', '/pack.zip'], ['plugins/Essentials', '/plugins/Essentials/pack.zip']]);

test('a missing chunk is 422 chunks_missing with its index, and nothing is uploaded (AC-FT3, EC-FT4)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, ['file.create']);
    foreach ([0, 1, 3, 4] as $index) {
        $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, $index, 5, 'xx'))->assertOk();
    }

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'xxxxxxxxxx'))
        ->assertStatus(422)->assertExactJson(['error' => 'chunks_missing', 'missing' => [2]]);

    expect($this->wings->uploads)->toBe([]);
});

test('the total comes from the first chunk, so a merge cannot claim fewer chunks than were announced', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, ['file.create']);
    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 3, 'AAA'))->assertOk();

    // The client would like this to be a one-chunk file; the upload says it has three.
    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'AAA'))
        ->assertStatus(422)->assertJsonPath('error', 'chunks_missing')->assertJsonPath('missing', [1, 2]);
});

test('a checksum that does not match the merged file is 422 and nothing is uploaded (AC-FT4)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, 'the whole file contents');

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'a different file'))
        ->assertStatus(422)->assertJsonPath('error', 'checksum_mismatch');

    expect($this->wings->uploads)->toBe([])
        ->and(is_dir($this->storeRoot.'/merged/'.Uploads::ID))->toBeFalse();
});

test('a file over the limit is refused before it is assembled (AC-FT5, FR-FT6)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->configure(['chunk_size_mb' => 1, 'max_file_mb' => 3]);
    $user = Uploads::subuser($server, ['file.create']);
    foreach ([0, 1, 2] as $index) {
        $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, $index, 3, str_repeat('a', 1048576)))->assertOk();
    }
    // The limit was lowered after the pieces were sent.
    $this->configure(['max_file_mb' => 2]);

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, str_repeat('a', 3 * 1048576)))
        ->assertStatus(422)->assertJsonPath('error', 'file_too_large');

    expect($this->wings->uploads)->toBe([])
        ->and(is_dir($this->storeRoot.'/merged'))->toBeFalse();
});

test('a target directory that could leave the server is 422 (AC-FT19, FR-FT20)', function (string $directory): void {
    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, 'abcd');

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd', $directory))
        ->assertStatus(422)->assertJsonPath('error', 'invalid_target_directory');

    expect($this->wings->uploads)->toBe([]);
})->with(['../../../', '/etc', 'a/../../b', 'mods;rm -rf /']);

test('a file name in a merge that could reach another path is 422 (T-FT3)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, 'abcd');

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd', 'mods', '../../escape.zip'))
        ->assertStatus(422)->assertJsonPath('error', 'invalid_filename');
});

test('an upload id that is a path never deletes or writes anything outside the store (T-FT3)', function (): void {
    [, $server] = $this->generateTestAccount();
    mkdir($this->storeRoot.'/decoy', 0700, true);
    file_put_contents($this->storeRoot.'/decoy/keep.txt', 'important');

    $this->actingAs(Uploads::subuser($server, ['file.create']))
        ->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge('../decoy', 'abcd'))
        ->assertStatus(422)->assertJsonPath('error', 'invalid_upload_id');

    expect(file_get_contents($this->storeRoot.'/decoy/keep.txt'))->toBe('important');
});

test('an upload that was never started is 404', function (): void {
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, ['file.create']))->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd'))
        ->assertNotFound()->assertJsonPath('error', 'upload_not_found');
});

test('another server cannot merge an upload it did not start', function (): void {
    [, $server] = $this->generateTestAccount();
    [, $other] = $this->generateTestAccount();
    ftSend($this, $server, 'abcd');

    $this->actingAs(Uploads::subuser($other, ['file.create']))->postJson(Uploads::url($other, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd'))
        ->assertNotFound();

    expect($this->wings->uploads)->toBe([]);
});

test('a merge under another file name than the upload was started with is a conflict', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, 'abcd');

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd', 'mods', 'other.zip'))
        ->assertStatus(422)->assertJsonPath('error', 'upload_id_conflict');
});

test('without the file.create permission a merge is refused (AC-FT13)', function (): void {
    [, $server] = $this->generateTestAccount();
    ftSend($this, $server, 'abcd');

    $this->actingAs(Uploads::subuser($server, ['file.read']))->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd'))->assertForbidden();
});

test('a merge that is already running is 409, so one upload is never written twice at once', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, 'abcd');
    $running = Cache::lock('file-transfer:merge:'.Uploads::ID, 60);
    $running->get();

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd'))
        ->assertStatus(409)->assertJsonPath('error', 'merge_in_progress');

    $running->release();
    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd'))->assertOk();
});

test('the lock is released after a merge, so the same user can start another upload', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, 'abcd');
    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd'))->assertOk();

    $free = Cache::lock('file-transfer:merge:'.Uploads::ID, 5);
    expect($free->get())->toBeTrue();
    $free->release();
});

test('when Wings refuses the file the answer is 503 upload_failed, the chunks stay for another try and the merged file is removed (EC-FT9)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, 'abcd');
    $this->wings->failWith = new TransferException('upload_failed', true);

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd'))
        ->assertStatus(503)->assertExactJson(['error' => 'upload_failed']);

    expect(app(ChunkStore::class)->missing(Uploads::ID, 1))->toBe([])
        ->and(is_dir($this->storeRoot.'/merged/'.Uploads::ID))->toBeFalse();

    $this->wings->failWith = null;
    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd'))->assertOk();
});

test('logs never hold the file name, the checksum or a path (NFR-FT8)', function (): void {
    $logged = [];
    Event::listen(MessageLogged::class, function (MessageLogged $event) use (&$logged): void {
        $logged[] = $event->message.' '.json_encode($event->context);
    });

    [, $server] = $this->generateTestAccount();
    $user = ftSend($this, $server, 'abcd', name: 'secret-world-backup.zip');
    $this->wings->failWith = new TransferException('upload_failed');

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk/merge'), Uploads::merge(Uploads::ID, 'abcd', 'private/dir', 'secret-world-backup.zip'))->assertStatus(503);

    $text = implode("\n", $logged);
    // Without this the checks below would pass for the wrong reason: the listener has to have seen the entry.
    expect($text)->toContain('file-transfer: merged upload failed')
        ->and($text)->not->toContain('secret-world-backup')
        ->and($text)->not->toContain('private/dir')
        ->and($text)->not->toContain(hash('sha256', 'abcd'));
});
