<?php

declare(strict_types=1);

use Illuminate\Contracts\Bus\Dispatcher;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use ModpackInstaller\Jobs\ProcessModpackInstallation;
use ModpackInstaller\Support\ModpackSource;
use ModpackInstaller\Tests\ExtensionTestCase;
use ModpackInstaller\Tests\Fixtures;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Extensions\ExtensionJobProgress;

uses(ExtensionTestCase::class);

const IC_FILE = 'https://api.curseforge.com/v1/mods/123/files/4002';

/** The body of an install request; the pack is the server pack of the fixtures. @param array<string, mixed> $over @return array<string, mixed> */
function icBody(array $over = []): array
{
    return ['source' => 'curseforge', 'project_id' => '123', 'file_id' => '4002', 'target_directory' => 'packs/atm9', ...$over];
}

/** CurseForge knows the file as a server pack. */
function icFileIsServerPack(array $over = []): void
{
    Http::fake([IC_FILE => Http::response(['data' => Fixtures::serverPack($over)])]);
}

/** @return array{0: Server, 1: Pterodactyl\Models\User} */
function icSetup(): array
{
    [, $server] = test()->generateTestAccount();

    return [$server, Fixtures::subuser($server, [Fixtures::INSTALL])];
}

function icRows(): array
{
    return DB::table('ext_modpack_installer_jobs')->get()->all();
}

describe('who may install (T-MI5, AC-MI5)', function (): void {
    it('refuses a subuser without the install permission, and neither asks the source nor queues anything', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [, $server] = $this->generateTestAccount();
        $user = Fixtures::subuser($server, ['file.create', 'file.read']);

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertForbidden();

        Http::assertNothingSent();
        Bus::assertNotDispatched(ProcessModpackInstallation::class);
        expect(icRows())->toBe([]);
    });

    it('refuses a guest, and someone who is not on the server', function (): void {
        $this->configureCurseForge();
        [, $server] = $this->generateTestAccount();

        $this->postJson(Fixtures::url($server, 'install'), icBody())->assertUnauthorized();
        $this->actingAs(Pterodactyl\Models\User::factory()->create())->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(404);
    });

    it('lets the owner of the server install', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$owner, $server] = $this->generateTestAccount();

        $this->actingAs($owner)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202);
    });
});

describe('a valid install (AC-MI6, FR-MI6)', function (): void {
    it('answers 202 with a job id, and queues the job with the ids and the folder, nothing else', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();

        $jobId = $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202)->json('job_id');

        Bus::assertDispatched(ProcessModpackInstallation::class, fn (ProcessModpackInstallation $job): bool => $job->serverUuid === $server->uuid
            && $job->source === ModpackSource::CurseForge
            && $job->projectId === '123'
            && $job->fileId === '4002'
            && $job->targetDirectory === 'packs/atm9'
            && $job->progressId === $jobId);
    });

    it('does not download anything in the request: only the file is looked up (FR-MI6)', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202);

        Http::assertSentCount(1);
        Http::assertSent(fn (Request $request): bool => $request->url() === IC_FILE && $request->header('X-API-Key') === [ExtensionTestCase::API_KEY]);
    });

    it('opens a progress record the user can follow, and that nobody else can read', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();

        $jobId = $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->json('job_id');
        $snapshot = app(ExtensionJobProgress::class)->find('modpack-installer', $jobId);

        expect($snapshot->status)->toBe('running')
            ->and($snapshot->percent)->toBe(0)
            ->and($snapshot->serverUuid)->toBe($server->uuid)
            ->and($snapshot->permission)->toBe(Fixtures::INSTALL)
            ->and($snapshot->userUuid)->toBe($user->uuid);

        $url = "/api/client/servers/{$server->uuid}/extension-progress/modpack-installer/{$jobId}";
        $this->actingAs($user)->getJson($url)->assertOk()->assertJsonPath('data.status', 'running');
        $this->actingAs(Fixtures::subuser($server, ['file.read']))->getJson($url)->assertStatus(404);
    });

    it('records the install in the table as pending, with the progress id', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();

        $jobId = $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->json('job_id');
        $rows = icRows();

        expect($rows)->toHaveCount(1)
            ->and($rows[0]->server_uuid)->toBe($server->uuid)
            ->and($rows[0]->source)->toBe('curseforge')
            ->and($rows[0]->project_id)->toBe('123')
            ->and($rows[0]->file_id)->toBe('4002')
            ->and($rows[0]->target_directory)->toBe('packs/atm9')
            ->and($rows[0]->job_id)->toBe($jobId)
            ->and($rows[0]->status)->toBe('pending');
    });

    it('installs into the root when no folder is given (FR-MI4)', function (mixed $folder): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();
        $body = icBody();
        unset($body['target_directory']);
        $body += $folder === false ? [] : ['target_directory' => $folder];

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), $body)->assertStatus(202);

        Bus::assertDispatched(ProcessModpackInstallation::class, fn (ProcessModpackInstallation $job): bool => $job->targetDirectory === '.');
    })->with(['omitted' => [false], 'empty' => [''], 'null' => [null], 'dot' => ['.']]);
});

describe('what the browser cannot decide (T-MI1, T-MI2)', function (): void {
    it('ignores an address, a key and a file description that it sends, and downloads nothing from them', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody([
            'download_url' => 'http://169.254.169.254/latest/meta-data/',
            'api_key' => 'attacker-key',
            'is_server_pack' => true,
            'file_data' => ['isServerPack' => true],
        ]))->assertStatus(202);

        Http::assertSentCount(1);
        Http::assertNotSent(fn (Request $request): bool => str_contains($request->url(), '169.254') || $request->header('X-API-Key') === ['attacker-key']);
        Bus::assertDispatched(ProcessModpackInstallation::class, fn (ProcessModpackInstallation $job): bool => ! property_exists($job, 'downloadUrl') && ! property_exists($job, 'apiKey'));
    });

    it('does not take its word that a file is a server pack: CurseForge decides (AC-MI7)', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack(['isServerPack' => false]);
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody(['is_server_pack' => true]))->assertStatus(422)->assertExactJson(['error' => 'not_server_pack']);

        Bus::assertNotDispatched(ProcessModpackInstallation::class);
        expect(icRows())->toBe([]);
    });
});

describe('what it refuses', function (): void {
    it('refuses a folder that could climb out of the server, and asks nobody (AC-MI14, FR-MI19)', function (string $folder): void {
        Bus::fake();
        $this->configureCurseForge();
        Http::fake();
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody(['target_directory' => $folder]))->assertStatus(422)->assertExactJson(['error' => 'invalid_target_directory']);

        Http::assertNothingSent();
        Bus::assertNotDispatched(ProcessModpackInstallation::class);
    })->with(['../etc', '/etc/passwd', 'a/../../b', '..', '/', 'a//b', 'my packs', 'a;b', 'a\b', 'café']);

    it('refuses a folder longer than 255 characters', function (): void {
        $this->configureCurseForge();
        Http::fake();
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody(['target_directory' => str_repeat('a', 256)]))->assertStatus(422);

        Http::assertNothingSent();
    });

    it('refuses a source that is not one of the two', function (string $source): void {
        $this->configureCurseForge();
        Http::fake();
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody(['source' => $source]))->assertStatus(422);

        Http::assertNothingSent();
    })->with(['github', 'CurseForge', 'http://evil.test', '']);

    it('refuses ids that are not of the source\'s shape, which would change the URL asked', function (array $over): void {
        $this->configureCurseForge();
        Http::fake();
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody($over))->assertStatus(422)->assertExactJson(['error' => 'invalid_id']);

        Http::assertNothingSent();
    })->with([
        'traversal in the project' => [['project_id' => '../x']],
        'query in the project' => [['project_id' => '1?x=2']],
        'letters in the project' => [['project_id' => 'abc']],
        'slash in the file' => [['file_id' => '1/2']],
        'too many digits' => [['file_id' => '12345678901']],
    ]);

    it('refuses a missing field', function (string $field): void {
        $this->configureCurseForge();
        [$server, $user] = icSetup();
        $body = icBody();
        unset($body[$field]);

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), $body)->assertStatus(422);
    })->with(['source', 'project_id', 'file_id']);

    it('says not_server_pack for Modrinth, which has no server packs, and asks nobody', function (): void {
        Bus::fake();
        Http::fake();
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody(['source' => 'modrinth', 'project_id' => 'AANobbMI', 'file_id' => 'bXr2Tk9d']))->assertStatus(422)->assertExactJson(['error' => 'not_server_pack']);

        Http::assertNothingSent();
        Bus::assertNotDispatched(ProcessModpackInstallation::class);
    });

    it('says curseforge_not_configured when there is no key', function (): void {
        Bus::fake();
        Http::fake();
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(503)->assertExactJson(['error' => 'curseforge_not_configured']);

        Http::assertNothingSent();
    });

    it('says file_not_found for a file CurseForge does not have, and queues nothing', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        Http::fake([IC_FILE => Http::response(['error' => 'x'], 404)]);
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(404)->assertExactJson(['error' => 'file_not_found']);

        Bus::assertNotDispatched(ProcessModpackInstallation::class);
        expect(icRows())->toBe([]);
    });

    it('says download_not_allowed for a pack whose author keeps it on CurseForge', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack(['downloadUrl' => null]);
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(422)->assertExactJson(['error' => 'download_not_allowed']);

        Bus::assertNotDispatched(ProcessModpackInstallation::class);
    });

    it('says download_too_large for a pack over the limit, before queueing anything (FR-MI8)', function (): void {
        Bus::fake();
        $this->configureCurseForge(['max_download_mb' => 10]);
        icFileIsServerPack(['fileLength' => 10 * 1048576 + 1]);
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(422)->assertExactJson(['error' => 'download_too_large']);

        Bus::assertNotDispatched(ProcessModpackInstallation::class);
    });

    it('accepts a pack of exactly the limit', function (): void {
        Bus::fake();
        $this->configureCurseForge(['max_download_mb' => 10]);
        icFileIsServerPack(['fileLength' => 10 * 1048576]);
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202);
    });

    it('says source_unavailable when CurseForge is down or cannot be reached, and not what it said', function (string $how): void {
        Bus::fake();
        $this->configureCurseForge();
        Http::fake([IC_FILE => $how === 'down' ? Http::response('trace at /var/www/app', 500) : fn () => throw new ConnectionException('timed out')]);
        [$server, $user] = icSetup();

        $response = $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(503);

        expect($response->json())->toBe(['error' => 'source_unavailable'])
            ->and($response->getContent())->not->toContain('/var/www');
        Bus::assertNotDispatched(ProcessModpackInstallation::class);
    })->with(['down', 'unreachable']);
});

describe('two installs of the same pack (EC-MI8, T-MI9)', function (): void {
    it('answers 409 install_in_progress to the second while the first has not finished', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202);
        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(409)->assertExactJson(['error' => 'install_in_progress']);

        Bus::assertDispatchedTimes(ProcessModpackInstallation::class, 1);
        expect(icRows())->toHaveCount(1);
    });

    it('also counts an install that is running', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();
        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202);
        DB::table('ext_modpack_installer_jobs')->update(['status' => 'running']);

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(409);
    });

    it('allows the same pack again once the first install has finished, either way', function (string $status): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();
        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202);
        DB::table('ext_modpack_installer_jobs')->update(['status' => $status]);

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202);

        expect(icRows())->toHaveCount(2);
    })->with(['completed', 'failed']);

    it('does not let an install that was lost block the pack for ever', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();
        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202);
        DB::table('ext_modpack_installer_jobs')->update(['updated_at' => now()->subHours(2)]);

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202);
    });

    it('allows another pack on the same server, and the same pack on another server', function (): void {
        Bus::fake();
        $this->configureCurseForge();
        // Whichever file is asked for is a server pack with that id.
        Http::fake(['api.curseforge.com/v1/mods/123/files/*' => fn (Request $request) => Http::response(['data' => Fixtures::serverPack(['id' => (int) basename($request->url())])])]);
        [$server, $user] = icSetup();
        [, $other] = $this->generateTestAccount();
        $otherUser = Fixtures::subuser($other, [Fixtures::INSTALL]);

        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202);
        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody(['file_id' => '4010']))->assertStatus(202);
        $this->actingAs($otherUser)->postJson(Fixtures::url($other, 'install'), icBody())->assertStatus(202);

        expect(icRows())->toHaveCount(3);
    });
});

describe('a queue that is down', function (): void {
    it('ends the record at once instead of leaving the browser and the next install waiting', function (): void {
        // Only this job fails to queue: the Panel queues other things of its own while it answers.
        $dispatcher = Mockery::mock(Dispatcher::class)->shouldIgnoreMissing();
        $dispatcher->shouldReceive('dispatch')->andReturnUsing(function (mixed $job): void {
            if ($job instanceof ProcessModpackInstallation) {
                throw new RuntimeException('queue is down');
            }
        });
        $this->app->instance(Dispatcher::class, $dispatcher);
        $this->configureCurseForge();
        icFileIsServerPack();
        [$server, $user] = icSetup();

        $jobId = $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(202)->json('job_id');
        $snapshot = app(ExtensionJobProgress::class)->find('modpack-installer', $jobId);
        $row = icRows()[0];

        expect($snapshot->status)->toBe('failed')
            ->and($snapshot->message)->toBe('download_failed')
            ->and($row->status)->toBe('failed')
            ->and($row->last_error)->toBe('download_failed');
    });
});

it('is limited to 30 requests a minute (FR-MI17, AC-MI16)', function (): void {
    Bus::fake();
    $this->configureCurseForge();
    icFileIsServerPack(['isServerPack' => false]);
    [$server, $user] = icSetup();

    for ($i = 0; $i < 30; $i++) {
        $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(422);
    }

    $this->actingAs($user)->postJson(Fixtures::url($server, 'install'), icBody())->assertStatus(429);
});
