<?php

declare(strict_types=1);

use Illuminate\Contracts\Queue\Job;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Factory;
use Illuminate\Http\Client\Request;
use Illuminate\Log\Events\MessageLogged;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use ModpackInstaller\Jobs\ProcessModpackInstallation;
use ModpackInstaller\Support\ModpackJobException;
use ModpackInstaller\Support\ModpackSettings;
use ModpackInstaller\Support\ModpackSource;
use ModpackInstaller\Support\TmpStore;
use ModpackInstaller\Support\WingsException;
use ModpackInstaller\Support\WingsFileService;
use ModpackInstaller\Tests\ExtensionTestCase;
use ModpackInstaller\Tests\Fixtures;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Extensions\ExtensionJobProgress;

uses(ExtensionTestCase::class);

const PJ_FILE = 'https://api.curseforge.com/v1/mods/123/files/4002';
const PJ_BODY = 'PK-the-archive-bytes';

/**
 * CurseForge knows the pack as a server pack, and its CDN has the archive.
 *
 * @param  array<string, mixed>  $file  what to change about the file CurseForge describes
 * @param  mixed  $cdn  what the CDN answers, if not the archive
 */
function pjFake(array $file = [], mixed $cdn = null): void
{
    $description = [...['hashes' => [['value' => sha1(PJ_BODY), 'algo' => 1]], 'fileLength' => strlen(PJ_BODY)], ...$file];

    Http::fake([
        PJ_FILE => Http::response(['data' => Fixtures::serverPack($description)]),
        'edge.forgecdn.net/*' => $cdn ?? Http::response(PJ_BODY, 200, ['Content-Length' => (string) strlen(PJ_BODY)]),
    ]);
}

/** A job for a fresh progress record and table row, as the controller would have queued it. @return array{0: ProcessModpackInstallation, 1: string} */
function pjJob(Server $server, string $directory = 'packs/atm9', ModpackSource $source = ModpackSource::CurseForge, bool $withKey = true): array
{
    // The job asks CurseForge with the key the admin stored.
    if ($withKey) {
        test()->configureCurseForge();
    }

    $record = app(ExtensionJobProgress::class)->begin('modpack-installer', User::factory()->create(), $server, Fixtures::INSTALL);
    DB::table('ext_modpack_installer_jobs')->insert([
        'server_uuid' => $server->uuid, 'source' => $source->value, 'project_id' => '123', 'file_id' => '4002', 'target_directory' => $directory,
        'job_id' => $record->id, 'status' => 'pending', 'created_at' => now(), 'updated_at' => now(),
    ]);

    return [new ProcessModpackInstallation($server->uuid, $source, '123', '4002', $directory, $record->id), $record->id];
}

function pjRun(ProcessModpackInstallation $job): void
{
    $job->handle(app(ExtensionJobProgress::class), app(ModpackSettings::class), app(TmpStore::class), app(Factory::class), app(WingsFileService::class));
}

/** Makes the queue say this is the last attempt, so a failure that could be retried is reported instead. */
function pjLastAttempt(ProcessModpackInstallation $job): ProcessModpackInstallation
{
    $queued = Mockery::mock(Job::class);
    $queued->shouldReceive('attempts')->andReturn($job->tries);
    $job->setJob($queued);

    return $job;
}

/** @return array{0: string, 1: string, 2: int} status, message and percent of a record */
function pjRecord(string $id): array
{
    $snapshot = app(ExtensionJobProgress::class)->find('modpack-installer', $id);

    return [$snapshot->status, $snapshot->message, $snapshot->percent];
}

function pjRow(string $id): object
{
    return DB::table('ext_modpack_installer_jobs')->where('job_id', $id)->first();
}

describe('a successful installation (AC-MI8)', function (): void {
    it('downloads the pack, hands it to the server, has it extracted and says so', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect($this->wings->uploads)->toBe([['server' => $server->uuid, 'path' => '/packs/atm9/modpack.zip', 'content' => PJ_BODY]])
            ->and($this->wings->decompressed)->toBe([['server' => $server->uuid, 'path' => '/packs/atm9/modpack.zip']])
            ->and(pjRecord($id))->toBe(['completed', 'Modpack installed successfully.', 100])
            ->and(pjRow($id)->status)->toBe('completed')
            ->and(pjRow($id)->last_error)->toBeNull();
    });

    it('does the steps in order, and removes the archive from the server once it is extracted', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job] = pjJob($server);

        pjRun($job);

        expect($this->wings->calls)->toBe([
            'upload /packs/atm9/modpack.zip',
            'decompress /packs/atm9/modpack.zip',
            'delete /packs/atm9/modpack.zip',
            'list /packs/atm9',
        ]);
    });

    it('reports each stage at the progress of the spec (FR-MI10)', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $seen = [];
        $this->wings->onCall = function (string $call) use (&$seen, $id): void {
            $record = pjRecord($id);
            $seen[explode(' ', $call)[0]] ??= [$record[2], $record[1]];
        };

        pjRun($job);

        expect($seen)->toBe([
            'upload' => [50, 'Uploading to server...'],
            'decompress' => [80, 'Extracting archive...'],
            'delete' => [80, 'Extracting archive...'],
            'list' => [95, 'Removing conflicting files...'],
        ]);
    });

    it('marks the install as running while it works', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $status = null;
        $this->wings->onCall = function () use (&$status, $id): void {
            $status ??= pjRow($id)->status;
        };

        pjRun($job);

        expect($status)->toBe('running');
    });

    it('installs into the root of the server when the folder is ".", never into "/."', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job] = pjJob($server, '.');

        pjRun($job);

        expect($this->wings->calls[0])->toBe('upload /modpack.zip')
            ->and($this->wings->calls[3])->toBe('list /');
    });

    it('asks CurseForge for the file again, with the stored key, and downloads from the address it gives', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job] = pjJob($server);

        pjRun($job);

        Http::assertSent(fn (Request $request): bool => $request->url() === PJ_FILE && $request->header('X-API-Key') === [ExtensionTestCase::API_KEY]);
        Http::assertSent(fn (Request $request): bool => $request->url() === Fixtures::CDN && $request->header('X-API-Key') === []);
        Http::assertSentCount(2);
    });

    it('follows a redirect of the CDN to another of its hosts', function (): void {
        Http::fake([
            PJ_FILE => Http::response(['data' => Fixtures::serverPack(['hashes' => [['value' => sha1(PJ_BODY), 'algo' => 1]]])]),
            'edge.forgecdn.net/*' => Http::response('', 302, ['Location' => 'https://mediafilez.forgecdn.net/files/pack.zip']),
            'mediafilez.forgecdn.net/*' => Http::response(PJ_BODY),
        ]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[0])->toBe('completed')
            ->and($this->wings->uploads[0]['content'])->toBe(PJ_BODY);
    });

    it('leaves nothing in the temporary store (NFR-MI6, AC-MI19)', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job] = pjJob($server);

        pjRun($job);

        expect(glob($this->tmpRoot.'/tmp/*') ?: [])->toBe([]);
    });

    it('is not undone by an archive that cannot be removed afterwards', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $this->wings->failDelete['/packs/atm9/modpack.zip'] = new WingsException('delete_failed');

        pjRun($job);

        expect(pjRecord($id)[0])->toBe('completed');
    });
});

describe('sanitizing (AC-MI9, AC-MI10, T-MI4)', function (): void {
    it('removes the launch scripts that are in the folder, and nothing else', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job] = pjJob($server);
        $this->wings->entries = ['start.sh', 'run.bat', 'world', 'server.properties', 'mods', 'ServerStart.bat'];

        pjRun($job);

        expect(array_column($this->wings->deleted, 'path'))->toBe([
            '/packs/atm9/modpack.zip',
            '/packs/atm9/start.sh',
            '/packs/atm9/run.bat',
            '/packs/atm9/ServerStart.bat',
        ]);
    });

    it('skips a script that is not there, without failing (AC-MI10, EC-MI10)', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $this->wings->entries = ['world', 'mods'];

        pjRun($job);

        expect(array_column($this->wings->deleted, 'path'))->toBe(['/packs/atm9/modpack.zip'])
            ->and(pjRecord($id)[0])->toBe('completed');
    });

    it('also removes what the admin added, but never an entry that is a path', function (): void {
        $this->configure(['extra_sanitized_files' => ['custom.sh', 'config/secrets.toml', '../world']]);
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job] = pjJob($server);
        $this->wings->entries = ['custom.sh', 'secrets.toml', 'world'];

        pjRun($job);

        expect(array_column($this->wings->deleted, 'path'))->toBe(['/packs/atm9/modpack.zip', '/packs/atm9/custom.sh']);
    });

    it('looks only at the folder the pack was extracted into: root scripts go when the folder is the root', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job] = pjJob($server, '.');
        $this->wings->entries = ['start.sh'];

        pjRun($job);

        expect(array_column($this->wings->deleted, 'path'))->toBe(['/modpack.zip', '/start.sh']);
    });
});

describe('every failure is one of the fixed codes, on the record the browser watches (FR-MI18)', function (): void {
    it('says file_not_found for a file CurseForge no longer has, and does not try again', function (): void {
        Http::fake([PJ_FILE => Http::response(['error' => 'x'], 404)]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[0])->toBe('failed')
            ->and(pjRecord($id)[1])->toBe('file_not_found')
            ->and(pjRow($id)->status)->toBe('failed')
            ->and(pjRow($id)->last_error)->toBe('file_not_found')
            ->and($this->wings->calls)->toBe([]);
    });

    it('says not_server_pack when CurseForge says the file is not one now', function (): void {
        pjFake(['isServerPack' => false]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('not_server_pack');
        Http::assertSentCount(1);
    });

    it('says not_server_pack for a source that has none, and asks nobody', function (): void {
        Http::fake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server, 'packs', ModpackSource::Modrinth);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('not_server_pack');
        Http::assertNothingSent();
    });

    it('says download_failed for a pack that may not be downloaded from here', function (): void {
        pjFake(['downloadUrl' => null]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('download_failed');
        Http::assertSentCount(1);
    });

    it('says download_too_large without downloading, when CurseForge already says the pack is too big (AC-MI11)', function (): void {
        $this->configure(['max_download_mb' => 10]);
        pjFake(['fileLength' => 10 * 1048576 + 1]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('download_too_large');
        Http::assertSentCount(1);
        expect($this->wings->calls)->toBe([]);
    });

    it('says download_too_large when the CDN announces more than the limit', function (): void {
        $this->configure(['max_download_mb' => 10]);
        pjFake([], Http::response('x', 200, ['Content-Length' => (string) (10 * 1048576 + 1)]));
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('download_too_large')
            ->and($this->wings->calls)->toBe([]);
    });

    it('says download_too_large when the CDN sends more than it announced or the limit', function (): void {
        $this->configure(['max_download_mb' => 10]);
        pjFake(['fileLength' => 100, 'hashes' => []], Http::response(str_repeat('x', 10 * 1048576 + 1)));
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('download_too_large')
            ->and($this->wings->calls)->toBe([])
            ->and(glob($this->tmpRoot.'/tmp/*') ?: [])->toBe([]);
    });

    it('says download_failed for an archive that is not the one CurseForge described', function (): void {
        pjFake([], Http::response('something else', 200));
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('download_failed')
            ->and($this->wings->calls)->toBe([]);
    });

    it('says download_failed for an address off the allow-list, and never asks it', function (string $url): void {
        pjFake(['downloadUrl' => $url]);
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('download_failed');
        Http::assertSentCount(1);
    })->with(['http://edge.forgecdn.net/a.zip', 'https://169.254.169.254/a.zip', 'https://evil.test/a.zip', 'https://127.0.0.1/a.zip']);

    it('says download_failed for a redirect off the allow-list, and never asks it', function (): void {
        pjFake([], Http::response('', 302, ['Location' => 'http://169.254.169.254/latest/meta-data/']));
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('download_failed');
        Http::assertNotSent(fn (Request $request): bool => str_contains($request->url(), '169.254'));
    });

    it('says download_failed when the CDN no longer has the file, and does not try again', function (): void {
        pjFake([], Http::response('', 404));
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('download_failed');
    });

    it('says upload_failed when Wings refuses the archive, and does not try again (AC-MI13)', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $this->wings->failUpload = new WingsException('upload_failed');

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('upload_failed')
            ->and($this->wings->calls)->toBe(['upload /packs/atm9/modpack.zip'])
            ->and(glob($this->tmpRoot.'/tmp/*') ?: [])->toBe([]);
    });

    it('says upload_failed when the server is gone (EC-MI7)', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $this->wings->failUpload = new WingsException('server_not_found');

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('upload_failed');
    });

    it('says extract_failed when Wings cannot extract the archive (EC-MI3), and does not sanitize', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $this->wings->failDecompress = new WingsException('extract_failed');

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('extract_failed')
            ->and($this->wings->calls)->toBe(['upload /packs/atm9/modpack.zip', 'decompress /packs/atm9/modpack.zip']);
    });

    it('says sanitize_failed when the folder cannot be listed, or a script cannot be removed', function (string $how): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $this->wings->entries = ['start.sh'];
        if ($how === 'list') {
            $this->wings->failList = new WingsException('list_failed');
        } else {
            $this->wings->failDelete['/packs/atm9/start.sh'] = new WingsException('delete_failed');
        }

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('sanitize_failed');
    })->with(['list', 'delete']);

    it('says only a code from the list, never a message', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $this->wings->failUpload = new WingsException('upload_failed');

        pjRun($job);

        expect(ModpackJobException::CODES)->toContain(pjRecord($id)[1]);
    });

    it('names the stage for a failure nobody planned for', function (string $stage, string $code): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $this->wings->onCall = function (string $call) use ($stage): void {
            if (str_starts_with($call, $stage)) {
                throw new RuntimeException('SQLSTATE[HY000] secret detail');
            }
        };

        pjRun($job);

        expect(pjRecord($id)[1])->toBe($code);
    })->with([['upload', 'upload_failed'], ['decompress', 'extract_failed'], ['list', 'sanitize_failed']]);

    it('names the download stage for a crash while downloading', function (): void {
        pjFake([], fn () => throw new RuntimeException('boom'));
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);

        pjRun($job);

        expect(pjRecord($id)[1])->toBe('download_failed');
    });

    it('never moves the progress backwards when it fails', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        $this->wings->failDecompress = new WingsException('extract_failed');

        pjRun($job);

        expect(pjRecord($id)[2])->toBe(80);
    });

    it('removes the temporary archive after a failure too (NFR-MI6)', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job] = pjJob($server);
        $this->wings->failUpload = new WingsException('upload_failed', unreachable: true);

        expect(fn () => pjRun($job))->toThrow(ModpackJobException::class);
        expect(glob($this->tmpRoot.'/tmp/*') ?: [])->toBe([]);
    });
});

/** Sets up one way a job can fail for a reason that may not repeat. */
function pjTransient(string $what, ExtensionTestCase $case): void
{
    match ($what) {
        'source down' => Http::fake([PJ_FILE => Http::response('', 503)]),
        'cdn busy' => pjFake([], Http::response('', 503)),
        'no connection' => Http::fake([PJ_FILE => fn () => throw new ConnectionException('timeout')]),
        'node unreachable' => pjFake(),
    };

    if ($what === 'node unreachable') {
        $case->wings->failUpload = new WingsException('upload_failed', unreachable: true);
    }
}

describe('trying again', function (): void {
    it('lets a failure that may not repeat go back to the queue, leaving the record running', function (string $what): void {
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        pjTransient($what, $this);

        expect(fn () => pjRun($job))->toThrow(ModpackJobException::class);

        expect(pjRecord($id)[0])->toBe('running')
            ->and(pjRow($id)->status)->toBe('running');
    })->with(['source down', 'cdn busy', 'no connection', 'node unreachable']);

    it('reports the failure on the last attempt, with the code', function (string $what, string $code): void {
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        pjTransient($what, $this);

        pjRun(pjLastAttempt($job));

        expect(pjRecord($id)[0])->toBe('failed')
            ->and(pjRecord($id)[1])->toBe($code)
            ->and(pjRow($id)->status)->toBe('failed');
    })->with([['source down', 'source_unavailable'], ['cdn busy', 'source_unavailable'], ['no connection', 'source_unavailable'], ['node unreachable', 'upload_failed']]);

    it('says source_unavailable when the stored key has gone', function (): void {
        Http::fake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server, withKey: false);

        pjRun(pjLastAttempt($job));

        expect(pjRecord($id)[1])->toBe('source_unavailable');
        Http::assertNothingSent();
    });

    it('does not undo a record that has finished', function (): void {
        pjFake();
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        pjRun($job);

        $job->failed(new RuntimeException('late'));

        expect(pjRecord($id)[0])->toBe('completed')
            ->and(pjRow($id)->status)->toBe('completed')
            ->and(pjRow($id)->last_error)->toBeNull();
    });

    it('is told by the queue when it ran out of time, and names the stage it was in', function (int $percent, string $code): void {
        [, $server] = $this->generateTestAccount();
        [$job, $id] = pjJob($server);
        if ($percent > 0) {
            app(ExtensionJobProgress::class)->update('modpack-installer', $id, $percent, 'working');
        }

        $job->failed(new RuntimeException('timed out'));

        expect(pjRecord($id)[0])->toBe('failed')
            ->and(pjRecord($id)[1])->toBe($code)
            ->and(pjRow($id)->last_error)->toBe($code);
    })->with([[0, 'download_failed'], [49, 'download_failed'], [50, 'upload_failed'], [80, 'extract_failed'], [95, 'sanitize_failed']]);
});

describe('the queue entry', function (): void {
    it('is unique per server, project and file, and keeps its limits (EC-MI6, EC-MI8)', function (): void {
        $job = new ProcessModpackInstallation('s-1', ModpackSource::CurseForge, '123', '4002', '.', 'p');
        $other = new ProcessModpackInstallation('s-1', ModpackSource::CurseForge, '123', '4003', '.', 'p2');

        expect($job->uniqueId())->toBe('mki-s-1-123-4002')
            ->and($other->uniqueId())->not->toBe($job->uniqueId())
            ->and($job->tries)->toBe(3)
            ->and($job->uniqueFor)->toBe(3600)
            ->and($job->timeout)->toBe(3600)
            ->and($job->backoff())->toBe([10, 30, 60]);
    });

    it('says whether it was queued', function (): void {
        Illuminate\Support\Facades\Bus::fake();

        expect(ProcessModpackInstallation::dispatchSafely('s', ModpackSource::CurseForge, '1', '2', '.', 'p'))->toBeTrue();
    });

    it('ends a record that will never run, and only a record that is still running', function (): void {
        [, $server] = $this->generateTestAccount();
        [, $id] = pjJob($server);
        [, $done] = pjJob($server);
        app(ExtensionJobProgress::class)->update('modpack-installer', $done, 100, 'ok', 'completed');

        ProcessModpackInstallation::abandon($id, 'download_failed');
        ProcessModpackInstallation::abandon($done, 'download_failed');

        expect(pjRecord($id))->toBe(['failed', 'download_failed', 0])
            ->and(pjRow($id)->status)->toBe('failed')
            ->and(pjRecord($done)[0])->toBe('completed')
            ->and(pjRow($done)->status)->toBe('pending');
    });
});

describe('what is logged (NFR-MI7, EC-MI13)', function (): void {
    it('carries no key and no download address on any path', function (string $path): void {
        $logs = [];
        Log::listen(function (MessageLogged $event) use (&$logs): void {
            $logs[] = $event->message.' '.json_encode($event->context);
        });
        match ($path) {
            'success' => pjFake(),
            'cdn down' => pjFake([], Http::response('', 500)),
            'wings down' => pjFake(),
            'crash' => pjFake([], fn () => throw new RuntimeException('failed to open https://edge.forgecdn.net/files/4000/001/atm9-server.zip with '.ExtensionTestCase::API_KEY)),
        };
        [, $server] = $this->generateTestAccount();
        [$job] = pjJob($server);
        $this->wings->entries = ['start.sh'];
        if ($path === 'wings down') {
            $this->wings->failUpload = new WingsException('upload_failed');
        }

        pjRun(pjLastAttempt($job));
        $job->failed(new RuntimeException('failed for '.Fixtures::CDN.' key '.ExtensionTestCase::API_KEY));

        $text = implode("\n", $logs);
        expect($text)->not->toContain(ExtensionTestCase::API_KEY)
            ->and($text)->not->toContain('forgecdn.net')
            ->and($text)->not->toContain('SQLSTATE');
    })->with(['success', 'cdn down', 'wings down', 'crash']);
});
