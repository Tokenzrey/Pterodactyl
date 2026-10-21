<?php

declare(strict_types=1);

use Illuminate\Contracts\Console\Kernel;

// Bootstrap test extension: memakai bootstrap Panel (migrate:fresh, menolak basis data yang namanya
// tidak mengandung "test"), menjalankan migrasi milik tiap extension, lalu mendaftarkan pemuat otomatis
// untuk namespace extension dan kelas dasar test-nya.
require '/app/bootstrap/tests.php';

// migrate:fresh di atas menghapus semua tabel, termasuk tabel extension; terapkan lagi migrasi yang belum
// tercatat. Aman diulang (FAST=1 melewati migrate:fresh tetapi tetap menerapkan migrasi baru).
(static function (): void {
    $app = require '/app/bootstrap/app.php';
    $kernel = $app->make(Kernel::class);
    $kernel->bootstrap();

    foreach (glob('/ext-src/*/database/migrations', GLOB_ONLYDIR) ?: [] as $path) {
        $status = $kernel->call('migrate', ['--path' => $path, '--realpath' => true, '--force' => true]);
        if ($status !== 0) {
            fwrite(STDERR, "migrasi gagal untuk $path\n".$kernel->output());
            exit(1);
        }
    }

    restore_error_handler();
    restore_exception_handler();
})();

spl_autoload_register(static function (string $class): void {
    $roots = [
        'OauthLogin\\Tests\\' => '/ext-src/oauth-login/tests/',
        'OauthLogin\\' => '/ext-src/oauth-login/src/',
        'SubdomainManager\\Tests\\' => '/ext-src/subdomain-manager/tests/',
        'SubdomainManager\\' => '/ext-src/subdomain-manager/src/',
        'PlayerManager\\Tests\\' => '/ext-src/player-manager/tests/',
        'PlayerManager\\' => '/ext-src/player-manager/src/',
        'MinecraftSuite\\Tests\\' => '/ext-src/minecraft-suite/tests/',
        'MinecraftSuite\\' => '/ext-src/minecraft-suite/src/',
        'ModpackInstaller\\Tests\\' => '/ext-src/modpack-installer/tests/',
        'ModpackInstaller\\' => '/ext-src/modpack-installer/src/',
        'FileTransfer\\Tests\\' => '/ext-src/file-transfer/tests/',
        'FileTransfer\\' => '/ext-src/file-transfer/src/',
        'MultiNodeSync\\Tests\\' => '/ext-src/multi-node-sync/tests/',
        'MultiNodeSync\\' => '/ext-src/multi-node-sync/src/',
    ];
    foreach ($roots as $prefix => $dir) {
        if (str_starts_with($class, $prefix)) {
            $file = $dir.str_replace('\\', '/', substr($class, strlen($prefix))).'.php';
            if (is_file($file)) {
                require $file;
            }

            return;
        }
    }
});
