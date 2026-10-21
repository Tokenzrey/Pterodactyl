<?php

declare(strict_types=1);

use Illuminate\Support\Facades\DB;
use ModpackInstaller\Support\TmpStore;
use ModpackInstaller\Tests\ExtensionTestCase;

uses(ExtensionTestCase::class);

const CC_ID = '550e8400-e29b-41d4-a716-446655440000';
const CC_OTHER = '6ba7b810-9dad-41d1-80b4-00c04fd430c8';

/** Puts an archive in the store and makes it this many hours old. */
function ccAged(ExtensionTestCase $case, string $id, int $hours): void
{
    $dir = app(TmpStore::class)->dir($id);
    file_put_contents("{$dir}/modpack.zip", 'archive');
    foreach ([$dir, "{$dir}/modpack.zip"] as $path) {
        touch($path, time() - $hours * 3600);
    }
}

function ccRow(string $status, int $daysOld, string $job): void
{
    DB::table('ext_modpack_installer_jobs')->insert([
        'server_uuid' => '11111111-2222-4333-8444-555555555555', 'source' => 'curseforge', 'project_id' => '123', 'file_id' => '4002', 'target_directory' => '.',
        'job_id' => $job, 'status' => $status, 'created_at' => now()->subDays($daysOld), 'updated_at' => now()->subDays($daysOld),
    ]);
}

it('deletes an archive that has waited more than two hours and keeps a newer one (T-MI12)', function (): void {
    ccAged($this, CC_ID, 3);
    ccAged($this, CC_OTHER, 1);

    $this->artisan('modpack-installer:cleanup')->expectsOutput('Deleted 1 old file(s).')->assertExitCode(0);

    expect(is_dir($this->tmpRoot.'/tmp/'.CC_ID))->toBeFalse()
        ->and(is_file($this->tmpRoot.'/tmp/'.CC_OTHER.'/modpack.zip'))->toBeTrue();
});

it('has nothing to do when there is nothing', function (): void {
    $this->artisan('modpack-installer:cleanup')->expectsOutput('Deleted 0 old file(s).')->assertExitCode(0);
});

it('removes finished installs older than thirty days, and keeps recent and unfinished ones', function (): void {
    ccRow('completed', 40, 'a');
    ccRow('failed', 40, 'b');
    ccRow('completed', 5, 'c');
    ccRow('pending', 40, 'd');
    ccRow('running', 40, 'e');

    $this->artisan('modpack-installer:cleanup')->assertExitCode(0);

    expect(DB::table('ext_modpack_installer_jobs')->orderBy('job_id')->pluck('job_id')->all())->toBe(['c', 'd', 'e']);
});
