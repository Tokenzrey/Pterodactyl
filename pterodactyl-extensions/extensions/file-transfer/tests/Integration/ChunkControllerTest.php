<?php

declare(strict_types=1);

use FileTransfer\Support\ChunkStore;
use FileTransfer\Tests\ExtensionTestCase;
use FileTransfer\Tests\Uploads;
use Pterodactyl\Models\User;

uses(ExtensionTestCase::class);

test('a chunk is accepted and the answer says how many are still to come (AC-FT1, FR-FT3)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, ['file.create']);

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 3, 'AAA'))
        ->assertOk()->assertExactJson(['accepted' => 0, 'remaining' => 2]);
    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 2, 3, 'CCC'))
        ->assertOk()->assertExactJson(['accepted' => 2, 'remaining' => 1]);
});

test('chunks may arrive in any order, and a repeated one replaces the first (EC-FT1, EC-FT2)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, ['file.create']);

    foreach ([[2, 'CCC'], [0, 'old'], [0, 'AAA'], [1, 'BBB']] as [$index, $bytes]) {
        $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, $index, 3, $bytes))->assertOk();
    }

    $store = app(ChunkStore::class);
    $store->mergeTo(Uploads::ID, 3, $store->mergedPath(Uploads::ID, 'pack.zip'));
    expect(file_get_contents($store->mergedPath(Uploads::ID, 'pack.zip')))->toBe('AAABBBCCC');
});

test('an empty chunk is accepted, because an empty file has one (EC-FT12)', function (): void {
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, ['file.create']))
        ->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 1, ''))
        ->assertOk()->assertExactJson(['accepted' => 0, 'remaining' => 0]);
});

test('without the file.create permission a chunk is refused and nothing is stored (AC-FT13)', function (): void {
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, ['file.read']))
        ->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 1, 'AAA'))
        ->assertForbidden();

    expect(app(ChunkStore::class)->missing(Uploads::ID, 1))->toBe([0]);
});

test('the server owner and a root administrator may upload without being given a permission', function (): void {
    [$owner, $server] = $this->generateTestAccount();

    $this->actingAs($owner)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 1, 'AAA'))->assertOk();
    $this->actingAs(User::factory()->create(['root_admin' => true]))
        ->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::OTHER_ID, 0, 1, 'BBB'))->assertOk();
});

test('a user who cannot open the server cannot upload to it', function (): void {
    [, $server] = $this->generateTestAccount();

    $this->actingAs(User::factory()->create())
        ->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 1, 'AAA'))
        ->assertNotFound();
});

test('a file name that could reach another path is 422 and nothing is stored (AC-FT6, T-FT3)', function (string $name): void {
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, ['file.create']))
        ->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 1, 'AAA', $name))
        ->assertStatus(422);

    expect(app(ChunkStore::class)->meta(Uploads::ID))->toBeNull();
})->with(['../../etc/passwd', '..', 'dir/file.zip', 'a\\b.zip']);

test('an upload id that is not a UUID is 422, so it can never become a path (T-FT3)', function (string $id): void {
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, ['file.create']))
        ->postJson(Uploads::url($server, 'chunk'), Uploads::chunk($id, 0, 1, 'AAA'))
        ->assertStatus(422)->assertJsonPath('error', 'invalid_upload_id');
})->with(['../../../tmp', 'not-a-uuid', '..']);

test('an index outside the range and a total outside 1 to 10000 are 422 (FR-FT2)', function (int $index, int $total, string $error): void {
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, ['file.create']))
        ->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, $index, $total, 'AAA'))
        ->assertStatus(422)->assertJsonPath('error', $error);
})->with([
    'index past the end' => [3, 3, 'invalid_chunk_index'],
    'negative index' => [-1, 3, 'invalid_chunk_index'],
    'no chunks at all' => [0, 0, 'invalid_total_chunks'],
    'too many chunks' => [0, 10001, 'invalid_total_chunks'],
]);

test('data that is not base64 is 422 (FR-FT2)', function (): void {
    [, $server] = $this->generateTestAccount();
    $body = [...Uploads::chunk(Uploads::ID, 0, 1, 'AAA'), 'data' => 'not base64 !!!'];

    $this->actingAs(Uploads::subuser($server, ['file.create']))->postJson(Uploads::url($server, 'chunk'), $body)
        ->assertStatus(422)->assertJsonPath('error', 'invalid_chunk_data');
});

test('a chunk whose checksum does not match its bytes is 422 and not stored (FR-FT2)', function (): void {
    [, $server] = $this->generateTestAccount();
    $body = [...Uploads::chunk(Uploads::ID, 0, 1, 'AAA'), 'checksum' => hash('sha256', 'something else')];

    $this->actingAs(Uploads::subuser($server, ['file.create']))->postJson(Uploads::url($server, 'chunk'), $body)
        ->assertStatus(422)->assertJsonPath('error', 'checksum_mismatch');

    expect(app(ChunkStore::class)->missing(Uploads::ID, 1))->toBe([0]);
});

test('a chunk larger than the chunk size setting is 422 (NFR-FT2)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->configure(['chunk_size_mb' => 1, 'max_file_mb' => 10]);

    $this->actingAs(Uploads::subuser($server, ['file.create']))
        ->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 2, str_repeat('a', 1048576 + 1)))
        ->assertStatus(422)->assertJsonPath('error', 'chunk_too_large');
});

test('a chunk of exactly the chunk size is accepted', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->configure(['chunk_size_mb' => 1, 'max_file_mb' => 10]);

    $this->actingAs(Uploads::subuser($server, ['file.create']))
        ->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 2, str_repeat('a', 1048576)))
        ->assertOk();
});

test('a file that could never fit is refused at its first chunk, before anything is written (FR-FT6)', function (): void {
    [, $server] = $this->generateTestAccount();
    $this->configure(['chunk_size_mb' => 1, 'max_file_mb' => 3]);

    $this->actingAs(Uploads::subuser($server, ['file.create']))
        ->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 4, 'AAA'))
        ->assertStatus(422)->assertJsonPath('error', 'file_too_large');

    expect(app(ChunkStore::class)->meta(Uploads::ID))->toBeNull();
});

test('the same upload id with another file name is 422 upload_id_conflict (EC-FT3, NFR-FT10)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, ['file.create']);
    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 2, 'AAA', 'first.zip'))->assertOk();

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 1, 2, 'BBB', 'second.zip'))
        ->assertStatus(422)->assertJsonPath('error', 'upload_id_conflict');
});

test('an upload id that belongs to another server is a conflict, so nobody writes into it', function (): void {
    [, $server] = $this->generateTestAccount();
    [, $other] = $this->generateTestAccount();
    $this->actingAs(Uploads::subuser($server, ['file.create']))->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 2, 'AAA'))->assertOk();

    $this->actingAs(Uploads::subuser($other, ['file.create']))->postJson(Uploads::url($other, 'chunk'), Uploads::chunk(Uploads::ID, 1, 2, 'EVIL'))
        ->assertStatus(422)->assertJsonPath('error', 'upload_id_conflict');

    expect(app(ChunkStore::class)->missing(Uploads::ID, 2))->toBe([1]);
});

test('two uploads to one server at once do not disturb each other (EC-FT11)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, ['file.create']);

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 0, 2, 'AAA', 'a.zip'))->assertOk()->assertJsonPath('remaining', 1);
    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::OTHER_ID, 0, 1, 'ZZZ', 'z.zip'))->assertOk()->assertJsonPath('remaining', 0);
    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 1, 2, 'BBB', 'a.zip'))->assertOk()->assertJsonPath('remaining', 0);
});

test('the 31st request in a minute is 429 (AC-FT18, FR-FT18)', function (): void {
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, ['file.create']);

    for ($i = 0; $i < 30; $i++) {
        $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, $i, 100, 'x'))->assertOk();
    }

    $this->actingAs($user)->postJson(Uploads::url($server, 'chunk'), Uploads::chunk(Uploads::ID, 30, 100, 'x'))->assertStatus(429);
});

test('a missing field is a 422 from validation, not an error', function (): void {
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, ['file.create']))->postJson(Uploads::url($server, 'chunk'), ['upload_id' => Uploads::ID])->assertStatus(422);
});
