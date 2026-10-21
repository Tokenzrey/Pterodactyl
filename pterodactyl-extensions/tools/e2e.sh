#!/usr/bin/env bash
# Uji ujung ke ujung di Panel nyata (image yang dipatok), memasang kedua paket dari dist/*.pteroext.
#
# Aman karena:
#  - semuanya hidup di jaringan Docker `internal` (tanpa jalan keluar): tidak ada panggilan ke Discord, GitHub, Google
#    atau Cloudflare, dan tidak ada port yang dibuka ke host; permintaan HTTP dijalankan dari DALAM kontainer Panel;
#  - hanya membuat dan menghapus sumber daya berawalan ptero-ext-e2e (2 kontainer dan 1 jaringan) serta $ENV_ROOT/e2e;
#  - rahasia (kata sandi basis data, kunci API admin) dibuat acak, disimpan di berkas mode 600 atau di dalam kontainer,
#    tidak pernah dicetak atau dipasang di baris perintah.
#
# usage: tools/e2e.sh        (jalankan tools/pack.sh <id> lebih dulu untuk kedua extension)
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
with_test_lock
need_docker

PREFIX=ptero-ext-e2e
NETW=$PREFIX-net DBC=$PREFIX-db PNL=$PREFIX-panel
E2E_DIR=$ENV_ROOT/e2e
HOST=panel.e2e.test

cleanup() {
    docker rm -f -v "$PNL" "$DBC" >/dev/null 2>&1
    docker network rm "$NETW" >/dev/null 2>&1
    [[ -n ${E2E_DIR:-} && $E2E_DIR == "$ENV_ROOT"/e2e ]] && rm -rf "$E2E_DIR"
}
trap cleanup EXIT
cleanup # sisa dari proses yang terputus (hanya nama di atas)

version_of() { sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$PROJECT/extensions/$1/extension.json" | head -n1; }
pkg() { echo "$PROJECT/dist/$1-$(version_of "$1").pteroext"; }
for id in oauth-login subdomain-manager player-manager minecraft-suite modpack-installer file-transfer multi-node-sync; do
    [[ -f $(pkg "$id") ]] || die "paket $(pkg "$id") belum ada; jalankan tools/pack.sh $id"
done

pass=0 failed=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
no() { failed=$((failed + 1)); printf '  GAGAL %s\n' "$1"; [[ -n ${2:-} ]] && printf '        %s\n' "$2"; }
has() { # has <nama> <yang diharapkan> <hasil>
    [[ $3 == *"$2"* ]] && ok "$1" || no "$1" "harap memuat [$2], dapat [${3:0:240}]"
}
lacks() { # lacks <nama> <yang tak boleh ada> <hasil>
    [[ $3 != *"$2"* ]] && ok "$1" || no "$1" "tidak boleh memuat [$2]"
}

# ---------- sumber daya
umask 077
mkdir -p "$E2E_DIR"
dbpw=$(openssl rand -hex 16)
{ echo "MARIADB_DATABASE=panel"; echo "MARIADB_USER=pterodactyl"; echo "MARIADB_PASSWORD=$dbpw"; echo "MARIADB_RANDOM_ROOT_PASSWORD=1"; } >"$E2E_DIR/db.env"
{
    echo "APP_URL=http://$HOST"; echo "APP_ENV=production"; echo "APP_DEBUG=false"; echo "APP_ENVIRONMENT_ONLY=false"
    echo "APP_SERVICE_AUTHOR=e2e@example.test"; echo "APP_TIMEZONE=UTC"
    echo "DB_HOST=$DBC"; echo "DB_PORT=3306"; echo "DB_DATABASE=panel"; echo "DB_USERNAME=pterodactyl"; echo "DB_PASSWORD=$dbpw"
    echo "CACHE_STORE=file"; echo "SESSION_DRIVER=file"; echo "QUEUE_CONNECTION=sync"; echo "MAIL_MAILER=array"
    echo "QUEUE_WORKER_ENABLED=false"; echo "SCHEDULER_ENABLED=false"; echo "LARAVEL_OPTIMIZE=false"
    echo "PTERODACTYL_TELEMETRY_ENABLED=false"; echo "PTERODACTYL_EXTENSIONS_ENABLED=true"
} >"$E2E_DIR/panel.env"

echo "== menyalakan stack sementara ($PREFIX*)"
docker network create --internal "$NETW" >/dev/null || die "gagal membuat jaringan"
docker run -d --name "$DBC" --network "$NETW" --env-file "$E2E_DIR/db.env" --tmpfs /var/lib/mysql "$MARIADB_IMAGE" >/dev/null || die "gagal menjalankan MariaDB"
for _ in $(seq 1 60); do
    docker exec "$DBC" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break
    sleep 2
done
docker exec "$DBC" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 || die "MariaDB tidak siap"
docker run -d --name "$PNL" --network "$NETW" --dns 192.0.2.1 --env-file "$E2E_DIR/panel.env" --security-opt no-new-privileges "$PANEL_IMAGE" >/dev/null || die "gagal menjalankan Panel"
for _ in $(seq 1 60); do
    [[ $(docker exec "$PNL" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ping 2>/dev/null) == 200 ]] && break
    sleep 2
done
[[ $(docker inspect -f '{{.State.Running}}' "$PNL") == true ]] || { docker logs "$PNL" 2>&1 | tail -n 20; die "Panel berhenti"; }

pc() { docker exec "$PNL" curl -sS --max-time 30 -H "Host: $HOST" "$@"; }
pa() { pc -H @/tmp/auth_header -H 'Accept: application/json' "$@"; }
art() { docker exec -u nginx "$PNL" php artisan --no-interaction --no-ansi "$@"; }
BOOT='<?php chdir("/app"); require "vendor/autoload.php"; $app = require "bootstrap/app.php"; $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();'
php_run() { { echo "$BOOT"; cat; } | docker exec -i -u nginx "$PNL" php; }

echo "== skema dan data awal Panel"
art migrate --force >/dev/null || die "migrate gagal"
art db:seed --force >/dev/null || die "seed gagal"

echo "== memasang paket"
for id in oauth-login subdomain-manager player-manager minecraft-suite modpack-installer file-transfer multi-node-sync; do
    docker cp "$(pkg "$id")" "$PNL:/tmp/$id.pteroext"
    out=$(art p:extension:install "/tmp/$id.pteroext" --enable 2>&1) || { echo "$out"; die "pemasangan $id gagal"; }
    has "p:extension:install --enable $id" "$id" "$out"
done
list=$(art p:extension:list 2>&1)
has "oauth-login terdaftar" "oauth-login" "$list"
has "subdomain-manager terdaftar" "subdomain-manager" "$list"
has "player-manager terdaftar" "player-manager" "$list"
has "minecraft-suite terdaftar" "minecraft-suite" "$list"
has "modpack-installer terdaftar" "modpack-installer" "$list"
has "file-transfer terdaftar" "file-transfer" "$list"
has "multi-node-sync terdaftar" "multi-node-sync" "$list"
lacks "tidak ada galat pemuatan" "failed" "$(echo "$list" | tr 'A-Z' 'a-z')"

tables=$(php_run <<'PHP'
foreach (['ext_oauth_login_identities', 'ext_subdomain_manager_records'] as $t) { echo $t, '=', json_encode(Illuminate\Support\Facades\Schema::hasTable($t)), ' '; }
PHP
)
has "migrasi oauth-login berjalan" "ext_oauth_login_identities=true" "$tables"
has "migrasi subdomain-manager berjalan" "ext_subdomain_manager_records=true" "$tables"

tables2=$(php_run <<'PHP'
foreach (['ext_modpack_installer_jobs', 'ext_multi_node_sync_migrations'] as $t) { echo $t, '=', json_encode(Illuminate\Support\Facades\Schema::hasTable($t)), ' '; }
PHP
)
has "migrasi modpack-installer berjalan" "ext_modpack_installer_jobs=true" "$tables2"
has "migrasi multi-node-sync berjalan" "ext_multi_node_sync_migrations=true" "$tables2"

# Pengaturan memakai nilai PALSU yang sengaja tidak berguna; tidak ada rahasia nyata di sini.
php_run <<'PHP' >/dev/null
use Illuminate\Support\Facades\Hash;
use Pterodactyl\Contracts\Api\CreatesApiKeys;
use Pterodactyl\Models\ApiKey;
use Pterodactyl\Models\User;
use Pterodactyl\Services\Extensions\ExtensionSettingsRegistry;

$registry = app(ExtensionSettingsRegistry::class);
$registry->get('oauth-login')->update(['enabled_providers' => ['discord'], 'discord_client_id' => 'e2e-client-id', 'discord_client_secret' => 'E2E-FAKE-SECRET-NOT-REAL']);
$registry->get('subdomain-manager')->update(['cloudflare_token' => 'e2e-fake-cloudflare-token', 'domains' => ['mc.e2e.test:0123456789abcdef0123456789abcdef'], 'target_ipv4' => '203.0.113.10']);
$registry->get('modpack-installer')->update(['curseforge_api_key' => 'E2E-FAKE-CURSEFORGE-KEY']);
$registry->get('multi-node-sync')->update(['s3_secret_key' => 'E2E-FAKE-S3-SECRET']);

$admin = User::query()->forceCreate(['uuid' => (string) Illuminate\Support\Str::uuid(), 'username' => 'e2eadmin', 'email' => 'e2e-admin@example.test', 'name_first' => 'E2E', 'name_last' => 'Admin', 'password' => Hash::make(bin2hex(random_bytes(16))), 'root_admin' => true, 'language' => 'en']);
$key = app(CreatesApiKeys::class)->create(ApiKey::TYPE_ACCOUNT, ['memo' => 'e2e', 'user_id' => $admin->id]);
file_put_contents('/tmp/auth_header', 'Authorization: Bearer '.$key->identifier.decrypt($key->token));
chmod('/tmp/auth_header', 0600);
PHP
[[ $(docker exec "$PNL" sh -c 'test -s /tmp/auth_header && echo yes') == yes ]] && ok "kunci API admin sementara dibuat di dalam kontainer" || no "kunci API admin tidak terbentuk"

# ---------- OAuth: rute publik, sesi nyata, halaman login
echo "== oauth-login"
hdr=$(pc -D - -o /dev/null -c /tmp/jar -b /tmp/jar "http://127.0.0.1/extensions/oauth-login/redirect/discord")
has "redirect/discord -> 302" " 302" "$hdr"
loc=$(echo "$hdr" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p')
has "mengarah ke discord.com/oauth2/authorize" "https://discord.com/oauth2/authorize?" "$loc"
has "client_id dari pengaturan" "client_id=e2e-client-id" "$loc"
has "redirect_uri dari APP_URL" "redirect_uri=http%3A%2F%2F$HOST%2Fextensions%2Foauth-login%2Fcallback%2Fdiscord" "$loc"
has "scope identify email" "scope=identify%20email" "$loc"
lacks "rahasia klien tidak ada di URL" "FAKE-SECRET" "$loc"
state=$(echo "$loc" | sed -n 's/.*[?&]state=\([^&]*\).*/\1/p')
[[ ${#state} -ge 22 ]] && ok "state sepanjang ${#state} karakter" || no "state terlalu pendek" "$state"

bad=$(pc -D - -o /dev/null -c /tmp/jar -b /tmp/jar "http://127.0.0.1/extensions/oauth-login/callback/discord?code=x&state=forged")
has "state salah -> invalid_state" "oauth_error=invalid_state" "$bad"
# Alur terbakar oleh percobaan salah di atas: butuh alur baru untuk uji berikutnya.
loc=$(pc -D - -o /dev/null -c /tmp/jar -b /tmp/jar "http://127.0.0.1/extensions/oauth-login/redirect/discord" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p')
state=$(echo "$loc" | sed -n 's/.*[?&]state=\([^&]*\).*/\1/p')
net=$(pc -D - -o /dev/null -c /tmp/jar -b /tmp/jar "http://127.0.0.1/extensions/oauth-login/callback/discord?code=fake-code&state=$state")
has "state benar, penyedia tak terjangkau (tanpa jalan keluar) -> provider_error" "oauth_error=provider_error" "$net"
again=$(pc -D - -o /dev/null -c /tmp/jar -b /tmp/jar "http://127.0.0.1/extensions/oauth-login/callback/discord?code=fake-code&state=$state")
has "state yang sama dipakai lagi -> invalid_state" "oauth_error=invalid_state" "$again"
has "penyedia tak dikenal -> 404" " 404" "$(pc -D - -o /dev/null http://127.0.0.1/extensions/oauth-login/redirect/gitlab)"
has "callback tanpa sesi -> invalid_state" "oauth_error=invalid_state" "$(pc -D - -o /dev/null 'http://127.0.0.1/extensions/oauth-login/callback/discord?code=x&state=y')"

page=$(pc "http://127.0.0.1/auth/login?oauth_error=no_account")
has "halaman login memuat bundel extension" '"id":"oauth-login"' "$page"
has "konfigurasi tamu hanya enabled_providers" '"enabled_providers":["discord"]' "$page"
lacks "halaman login tanpa rahasia klien" "FAKE-SECRET" "$page"
lacks "halaman login tanpa client_id" "e2e-client-id" "$page"
# O JSON di HTML meloloskan garis miring (\/); kembalikan sebelum dipakai sebagai alamat.
asset=$(echo "$page" | grep -o '"id":"oauth-login","entry":"[^"]*"' | head -n1 | sed 's/.*"entry":"//; s/"$//; s#\\/#/#g')
if [[ -n $asset ]]; then
    ah=$(pc -D - -o /dev/null "http://127.0.0.1$asset")
    has "aset client.js dilayani ($asset)" " 200" "$ah"
    has "aset dengan nosniff" "nosniff" "$(echo "$ah" | tr 'A-Z' 'a-z')"
else
    no "alamat client.js tidak ditemukan di halaman login" "$(echo "$page" | grep -o '.\{120\}oauth-login.\{260\}' | head -n2 | tr '\n' ' ')"
fi

has "API admin menolak tamu (oauth-login)" " 401" "$(pc -D - -o /dev/null -H 'Accept: application/json' http://127.0.0.1/api/admin/extensions/oauth-login/settings)"
settings=$(pa http://127.0.0.1/api/admin/extensions/oauth-login/settings)
has "admin membaca pengaturan" '"registered":true' "$settings"
has "rahasia klien tampil sebagai topeng" '********' "$settings"
lacks "rahasia klien tidak bocor di API pengaturan" "FAKE-SECRET" "$settings"

# ---------- Subdomain Manager: rute admin
echo "== subdomain-manager"
has "API admin menolak tamu (subdomain-manager)" " 401" "$(pc -D - -o /dev/null -H 'Accept: application/json' http://127.0.0.1/api/admin/extensions/subdomain-manager/config)"
cfg=$(pa http://127.0.0.1/api/admin/extensions/subdomain-manager/config)
has "config: daftar domain" '"domains":["mc.e2e.test"]' "$cfg"
lacks "config tanpa token" "e2e-fake-cloudflare-token" "$cfg"
lacks "config tanpa zone id" "0123456789abcdef0123456789abcdef" "$cfg"
av=$(pa "http://127.0.0.1/api/admin/extensions/subdomain-manager/availability?domain=mc.e2e.test&label=kampung")
has "availability: Cloudflare tak terjangkau -> tersedia tapi belum dicek" '"available":true' "$av"
has "availability menandai belum dicek di Cloudflare" '"checked_cloudflare":false' "$av"
has "availability: label dicadangkan" '"reason":"reserved"' "$(pa 'http://127.0.0.1/api/admin/extensions/subdomain-manager/availability?domain=mc.e2e.test&label=www')"
has "availability: domain di luar daftar" '"reason":"unconfigured"' "$(pa 'http://127.0.0.1/api/admin/extensions/subdomain-manager/availability?domain=evil.example&label=kampung')"
tsettings=$(pa http://127.0.0.1/api/admin/extensions/subdomain-manager/settings)
lacks "token Cloudflare tidak bocor di API pengaturan" "e2e-fake-cloudflare-token" "$tsettings"
has "form server memuat extension (admin.server)" "subdomain-manager" "$(pa http://127.0.0.1/api/admin/extensions/forms)"
has "perintah reconcile terdaftar" "subdomain-manager:reconcile" "$(art list subdomain-manager 2>&1)"
sched=$(art schedule:list 2>&1)
has "reconcile terjadwal" "subdomain-manager:reconcile" "$sched"
rec=$(art subdomain-manager:reconcile 2>&1)
has "reconcile berjalan tanpa galat" "Queued 0" "$rec"

# ---------- halaman dan API baru: menautkan akun, Connected accounts, ringkasan dan daftar subdomain
echo "== fitur baru"
linkg=$(pc -D - -o /dev/null http://127.0.0.1/extensions/oauth-login/link/discord)
has "tautkan akun: tamu diarahkan ke login, bukan ke penyedia" " 302" "$linkg"
lacks "tautkan akun: tamu tidak dikirim ke discord.com" "discord.com" "$linkg"
has "Connected accounts: API menolak tamu (401)" " 401" "$(pc -D - -o /dev/null -H 'Accept: application/json' http://127.0.0.1/api/client/extensions/oauth-login/accounts)"
accounts=$(pa http://127.0.0.1/api/client/extensions/oauth-login/accounts)
has "Connected accounts: penyedia aktif terdaftar" '"id":"discord","label":"Discord","enabled":true,"linked":false' "$accounts"
lacks "Connected accounts: tanpa client_id atau rahasia" "e2e-client-id" "$accounts"
has "halaman Connected accounts dilayani" "200" "$(pc -o /dev/null -w '%{http_code}' http://127.0.0.1/account/connected-accounts)"
has "halaman Subdomains (admin) dilayani" "200" "$(pc -o /dev/null -w '%{http_code}' http://127.0.0.1/panel/subdomains)"
has "API admin ringkasan menolak tamu (401)" " 401" "$(pc -D - -o /dev/null -H 'Accept: application/json' http://127.0.0.1/api/admin/extensions/subdomain-manager/overview)"
overview=$(pa http://127.0.0.1/api/admin/extensions/subdomain-manager/overview)
has "ringkasan: token tersimpan dan 1 domain" '"token":true' "$overview"
has "ringkasan: 1 domain" '"domains":1' "$overview"
lacks "ringkasan tanpa token" "e2e-fake-cloudflare-token" "$overview"
has "daftar subdomain kosong" '"data":[]' "$(pa http://127.0.0.1/api/admin/extensions/subdomain-manager/records)"
code=$(pa -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1/api/admin/extensions/subdomain-manager/records/999999/retry)
[[ $code == 404 ]] && ok "coba ulang baris yang tidak ada -> 404" || no "coba ulang baris yang tidak ada" "kode $code"
conn=$(pa -X POST http://127.0.0.1/api/admin/extensions/subdomain-manager/test)
has "uji koneksi: tiap domain punya hasil" '"domain":"mc.e2e.test"' "$conn"
lacks "uji koneksi tanpa token" "e2e-fake-cloudflare-token" "$conn"

# ---------- player-manager dan minecraft-suite: izin, rute server, form admin, bundel
# Tidak ada Wings dan server game di sini: yang dibuktikan hanya apa yang bisa dibuktikan di Panel nyata tanpa keduanya.
echo "== player-manager dan minecraft-suite"
perms=$(php_run <<'PHP'
$all = app(Pterodactyl\Services\Extensions\ExtensionPermissionRegistry::class)->all();
foreach (['ext.player-manager', 'ext.minecraft-suite'] as $g) { echo $g, '=', implode(',', array_keys($all[$g]['keys'] ?? [])), ' '; }
PHP
)
has "izin player-manager terdaftar di Panel nyata" "ext.player-manager=read,kick,ban,op,deop" "$perms"
has "izin minecraft-suite terdaftar di Panel nyata" "ext.minecraft-suite=read" "$perms"

SRV=00000000-0000-4000-8000-000000000000 # server yang tidak ada: cukup untuk membuktikan rute dan penjaganya
for path in player-manager/players minecraft-suite/health; do
    has "rute server menolak tamu ($path)" " 401" "$(pc -D - -o /dev/null -H 'Accept: application/json' "http://127.0.0.1/api/client/servers/$SRV/extensions/$path")"
    code=$(pa -o /dev/null -w '%{http_code}' "http://127.0.0.1/api/client/servers/$SRV/extensions/$path")
    [[ $code == 404 ]] && ok "rute server dikenal; server yang tidak ada -> 404 ($path)" || no "rute server tidak sesuai harapan ($path)" "kode $code"
done
for action in kick ban op deop; do
    has "aksi $action menolak tamu" " 401" "$(pc -D - -o /dev/null -X POST -H 'Accept: application/json' "http://127.0.0.1/api/client/servers/$SRV/extensions/player-manager/players/Steve/$action")"
done

forms=$(pa http://127.0.0.1/api/admin/extensions/forms)
has "form server memuat bidang player-manager" "player-manager" "$forms"
has "form server memuat bidang minecraft-suite" "minecraft-suite" "$forms"

page=$(pc "http://127.0.0.1/auth/login")
for id in player-manager minecraft-suite; do
    has "halaman memuat bundel $id" "\"id\":\"$id\"" "$page"
    asset=$(echo "$page" | grep -o "\"id\":\"$id\",\"entry\":\"[^\"]*\"" | head -n1 | sed 's/.*"entry":"//; s/"$//; s#\\/#/#g')
    if [[ -n $asset ]]; then
        ah=$(pc -D - -o /dev/null "http://127.0.0.1$asset")
        has "aset client.js $id dilayani" " 200" "$ah"
    else
        no "alamat client.js $id tidak ditemukan di halaman"
    fi
done

# ---------- modpack-installer: rute server, pengaturan, izin
echo "== modpack-installer"
SRV=00000000-0000-4000-8000-000000000000
has "rute search menolak tamu" " 401" "$(pc -D - -o /dev/null -H 'Accept: application/json' "http://127.0.0.1/api/client/servers/$SRV/extensions/modpack-installer/search")"
has "rute install menolak tamu" " 401" "$(pc -D - -o /dev/null -X POST -H 'Accept: application/json' "http://127.0.0.1/api/client/servers/$SRV/extensions/modpack-installer/install")"
has "rute default server menolak tamu" " 401" "$(pc -D - -o /dev/null -H 'Accept: application/json' "http://127.0.0.1/api/client/servers/$SRV/extensions/modpack-installer/defaults")"
misettings=$(pa http://127.0.0.1/api/admin/extensions/modpack-installer/settings)
has "API key CurseForge tampil sebagai topeng" '********' "$misettings"
lacks "API key CurseForge tidak bocor di API pengaturan" "E2E-FAKE-CURSEFORGE-KEY" "$misettings"
miperms=$(php_run <<'PHP'
$all = app(Pterodactyl\Services\Extensions\ExtensionPermissionRegistry::class)->all();
echo implode(',', array_keys($all['ext.modpack-installer']['keys'] ?? []));
PHP
)
has "izin modpack-installer terdaftar" "install" "$miperms"
has "perintah cleanup modpack-installer terdaftar" "modpack-installer:cleanup" "$(art list modpack-installer 2>&1)"
misched=$(art schedule:list 2>&1)
has "cleanup modpack-installer terjadwal" "modpack-installer:cleanup" "$misched"
mipage=$(pc "http://127.0.0.1/auth/login")
has "halaman memuat bundel modpack-installer" '"id":"modpack-installer"' "$mipage"

# ---------- file-transfer: rute server, pengaturan, izin, cleanup
echo "== file-transfer"
has "rute chunk upload menolak tamu" " 401" "$(pc -D - -o /dev/null -X POST -H 'Accept: application/json' "http://127.0.0.1/api/client/servers/$SRV/extensions/file-transfer/chunk")"
has "rute chunk merge menolak tamu" " 401" "$(pc -D - -o /dev/null -X POST -H 'Accept: application/json' "http://127.0.0.1/api/client/servers/$SRV/extensions/file-transfer/chunk/merge")"
has "rute remote-fetch menolak tamu" " 401" "$(pc -D - -o /dev/null -X POST -H 'Accept: application/json' "http://127.0.0.1/api/client/servers/$SRV/extensions/file-transfer/remote-fetch")"
ftsettings=$(pa http://127.0.0.1/api/admin/extensions/file-transfer/settings)
has "pengaturan file-transfer terbaca" '"registered":true' "$ftsettings"
ftperms=$(php_run <<'PHP'
$all = app(Pterodactyl\Services\Extensions\ExtensionPermissionRegistry::class)->all();
echo implode(',', array_keys($all['ext.file-transfer']['keys'] ?? []));
PHP
)
has "izin file-transfer terdaftar" "remote-fetch" "$ftperms"
has "perintah cleanup terdaftar" "file-transfer:cleanup" "$(art list file-transfer 2>&1)"
ftsched=$(art schedule:list 2>&1)
has "cleanup terjadwal" "file-transfer:cleanup" "$ftsched"
ftpage=$(pc "http://127.0.0.1/auth/login")
has "halaman memuat bundel file-transfer" '"id":"file-transfer"' "$ftpage"

# ---------- multi-node-sync: rute admin, S3 config, izin, cleanup
echo "== multi-node-sync"
has "API admin menolak tamu (multi-node-sync S3 config)" " 401" "$(pc -D - -o /dev/null -H 'Accept: application/json' http://127.0.0.1/api/admin/extensions/multi-node-sync/s3/config)"
has "API admin menolak tamu (multi-node-sync presign)" " 401" "$(pc -D - -o /dev/null -X POST -H 'Accept: application/json' http://127.0.0.1/api/admin/extensions/multi-node-sync/s3/presign)"
has "API admin menolak tamu (multi-node-sync migrations)" " 401" "$(pc -D - -o /dev/null -X POST -H 'Accept: application/json' http://127.0.0.1/api/admin/extensions/multi-node-sync/migrations)"
mnsettings=$(pa http://127.0.0.1/api/admin/extensions/multi-node-sync/settings)
has "S3 secret key tampil sebagai topeng" '********' "$mnsettings"
lacks "S3 secret key tidak bocor di API pengaturan" "E2E-FAKE-S3-SECRET" "$mnsettings"
mncfg=$(pa http://127.0.0.1/api/admin/extensions/multi-node-sync/s3/config)
has "S3 config: configured false secara default" '"configured":false' "$mncfg"
lacks "S3 config tanpa kredensial" "access_key" "$mncfg"
lacks "S3 config tanpa secret key" "secret_key" "$mncfg"
mnperms=$(php_run <<'PHP'
$all = app(Pterodactyl\Services\Extensions\ExtensionPermissionRegistry::class)->all();
echo implode(',', array_keys($all['ext.multi-node-sync']['keys'] ?? []));
PHP
)
has "izin multi-node-sync terdaftar" "migrate,s3-presign" "$mnperms"
has "perintah cleanup multi-node-sync terdaftar" "multi-node-sync:cleanup" "$(art list multi-node-sync 2>&1)"
mnsched=$(art schedule:list 2>&1)
has "cleanup multi-node-sync terjadwal" "multi-node-sync:cleanup" "$mnsched"
mnpage=$(pc "http://127.0.0.1/auth/login")
has "halaman memuat bundel multi-node-sync" '"id":"multi-node-sync"' "$mnpage"

# ---------- siklus hidup
echo "== siklus hidup"
art p:extension:disable oauth-login >/dev/null 2>&1
off=$(pc -D - -o /dev/null http://127.0.0.1/extensions/oauth-login/redirect/discord)
lacks "setelah disable, redirect tidak lagi 302 ke penyedia" " 302" "$off"
art p:extension:enable oauth-login >/dev/null 2>&1
on=$(pc -D - -o /dev/null http://127.0.0.1/extensions/oauth-login/redirect/discord)
has "setelah enable, redirect kembali" " 302" "$on"
has "data (pengaturan) bertahan melewati disable/enable" "client_id=e2e-client-id" "$(echo "$on" | tr -d '\r')"

# 21 permintaan: yang ke-21 dari satu alamat harus 429
last=""
for i in $(seq 1 25); do last=$(pc -o /dev/null -w '%{http_code}' http://127.0.0.1/extensions/oauth-login/redirect/discord); done
[[ $last == 429 ]] && ok "pembatasan laju: 429 setelah batas" || no "pembatasan laju tidak terpicu" "kode terakhir $last"

echo
echo "== hasil: $pass lulus, $failed gagal"
[[ $failed -eq 0 ]]
