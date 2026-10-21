<?php

declare(strict_types=1);

use FileTransfer\Jobs\FetchRemoteFile;
use FileTransfer\Tests\ExtensionTestCase;
use FileTransfer\Tests\Uploads;
use Illuminate\Support\Facades\Bus;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Extensions\ExtensionJobProgress;

uses(ExtensionTestCase::class);

const FT_FETCH = 'ext.file-transfer.remote-fetch';

function ftFetch(array $over = []): array
{
    return ['url' => 'https://example.com/files/pack.zip', 'target_directory' => 'mods', ...$over];
}

test('a valid URL is queued and answered with 202 and a job id, without any download in the request (AC-FT7, FR-FT9)', function (): void {
    Bus::fake();
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, [FT_FETCH]);

    $response = $this->actingAs($user)->postJson(Uploads::url($server, 'remote-fetch'), ftFetch())->assertStatus(202);

    $jobId = $response->json('job_id');
    Bus::assertDispatched(FetchRemoteFile::class, fn (FetchRemoteFile $job): bool => $job->serverUuid === $server->uuid
        && $job->url === 'https://example.com/files/pack.zip'
        && $job->targetDirectory === 'mods'
        && $job->filename === 'pack.zip'
        && $job->progressId === $jobId);
});

test('the job id is a progress record the user can read, and nobody else can (FR-FT9)', function (): void {
    Bus::fake();
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, [FT_FETCH]);

    $jobId = $this->actingAs($user)->postJson(Uploads::url($server, 'remote-fetch'), ftFetch())->json('job_id');
    $snapshot = app(ExtensionJobProgress::class)->find('file-transfer', $jobId);

    expect($snapshot->status)->toBe('running')
        ->and($snapshot->percent)->toBe(0)
        ->and($snapshot->serverUuid)->toBe($server->uuid)
        ->and($snapshot->permission)->toBe(FT_FETCH)
        ->and($snapshot->userUuid)->toBe($user->uuid);

    // The Panel's own progress route: readable with the remote-fetch permission, a 404 without it.
    $progress = "/api/client/servers/{$server->uuid}/extension-progress/file-transfer/{$jobId}";
    $this->actingAs($user)->getJson($progress)->assertOk()->assertJsonPath('data.status', 'running')->assertJsonPath('data.percent', 0);
    $this->actingAs(Uploads::subuser($server, ['file.create']))->getJson($progress)->assertNotFound();
});

test('a user without the remote-fetch permission is refused and nothing is queued (AC-FT14)', function (): void {
    Bus::fake();
    [, $server] = $this->generateTestAccount();

    // file.create is the chunk permission, not this one.
    $this->actingAs(Uploads::subuser($server, ['file.create']))->postJson(Uploads::url($server, 'remote-fetch'), ftFetch())->assertForbidden();

    Bus::assertNotDispatched(FetchRemoteFile::class);
});

test('the owner and a root administrator may fetch without being given the permission', function (): void {
    Bus::fake();
    [$owner, $server] = $this->generateTestAccount();

    $this->actingAs($owner)->postJson(Uploads::url($server, 'remote-fetch'), ftFetch())->assertStatus(202);
    $this->actingAs(User::factory()->create(['root_admin' => true]))->postJson(Uploads::url($server, 'remote-fetch'), ftFetch())->assertStatus(202);
});

test('a URL that points inside the network is 422 invalid_url and nothing is queued (AC-FT8, AC-FT9, T-FT1)', function (string $url): void {
    Bus::fake();
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, [FT_FETCH]))->postJson(Uploads::url($server, 'remote-fetch'), ftFetch(['url' => $url]))
        ->assertStatus(422)->assertExactJson(['error' => 'invalid_url']);

    Bus::assertNotDispatched(FetchRemoteFile::class);
})->with([
    'cloud metadata' => ['http://169.254.169.254/latest/meta-data/'],
    'localhost' => ['http://localhost:6379/'],
    'loopback' => ['http://127.0.0.1/'],
    'a private address' => ['http://10.0.0.1/'],
    'a bracketed loopback' => ['http://[::1]:6379/'],
    'a hex address' => ['http://0x7f.0.0.1/'],
    'another scheme' => ['ftp://example.com/file.zip'],
    'file' => ['file:///etc/passwd'],
    'credentials' => ['https://user:pass@example.com/'],
]);

test('a target directory that could leave the server is 422 (AC-FT19, FR-FT20)', function (string $directory): void {
    Bus::fake();
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, [FT_FETCH]))->postJson(Uploads::url($server, 'remote-fetch'), ftFetch(['target_directory' => $directory]))
        ->assertStatus(422)->assertJsonPath('error', 'invalid_target_directory');

    Bus::assertNotDispatched(FetchRemoteFile::class);
})->with(['../../../', '/etc', 'a/../b']);

test('the file name is taken from the URL, cut down to safe characters (FR-FT7, EC-FT10)', function (string $url, string $expected): void {
    Bus::fake();
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, [FT_FETCH]))->postJson(Uploads::url($server, 'remote-fetch'), ftFetch(['url' => $url]))->assertStatus(202);

    Bus::assertDispatched(FetchRemoteFile::class, fn (FetchRemoteFile $job): bool => $job->filename === $expected);
})->with([
    'the last segment' => ['https://example.com/a/b/server.jar', 'server.jar'],
    'a query is not part of it' => ['https://example.com/pack.zip?token=abc', 'pack.zip'],
    'percent-encoding is decoded and cleaned' => ['https://example.com/my%20mod%21.jar', 'mymod.jar'],
    'nothing usable' => ['https://example.com/', 'downloaded_file'],
    'only unsafe characters' => ['https://example.com/%24%24%24', 'downloaded_file'],
    'a traversal in the path' => ['https://example.com/%2e%2e%2f%2e%2e%2fpasswd', 'passwd'],
]);

test('a file name the user gives is used, and an unsafe one is 422 (EC-FT10)', function (): void {
    Bus::fake();
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, [FT_FETCH]);

    $this->actingAs($user)->postJson(Uploads::url($server, 'remote-fetch'), ftFetch(['filename' => 'renamed.zip']))->assertStatus(202);
    Bus::assertDispatched(FetchRemoteFile::class, fn (FetchRemoteFile $job): bool => $job->filename === 'renamed.zip');

    $this->actingAs($user)->postJson(Uploads::url($server, 'remote-fetch'), ftFetch(['filename' => '../../x']))
        ->assertStatus(422)->assertJsonPath('error', 'invalid_filename');
});

test('the 31st request in a minute is 429 (AC-FT18)', function (): void {
    Bus::fake();
    [, $server] = $this->generateTestAccount();
    $user = Uploads::subuser($server, [FT_FETCH]);

    for ($i = 0; $i < 30; $i++) {
        $this->actingAs($user)->postJson(Uploads::url($server, 'remote-fetch'), ftFetch())->assertStatus(202);
    }

    $this->actingAs($user)->postJson(Uploads::url($server, 'remote-fetch'), ftFetch())->assertStatus(429);
});

test('missing fields are a 422 from validation', function (): void {
    [, $server] = $this->generateTestAccount();

    $this->actingAs(Uploads::subuser($server, [FT_FETCH]))->postJson(Uploads::url($server, 'remote-fetch'), ['target_directory' => 'mods'])->assertStatus(422);
});
