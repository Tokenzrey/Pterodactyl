#!/usr/bin/env bash
# shellcheck shell=bash
# ./ptero egg build | install : the Minecraft modpack egg (eggs/modpack-installer). Sourced by ./ptero.
#
# The egg is plain Pterodactyl data (PTDL_v2): no Panel extension is involved. `egg install` imports it into the Panel
# through the Panel's own import action (the same code the admin UI uses), or updates it in place when it exists.

# egg_install_run: import or update the modpack egg in the (running, healthy) Panel. Used by `egg install` and by `setup`.
egg_install_run() {
    local json="$PTERO_TMP/egg.json" php="$PTERO_TMP/egg-import.php" key="" out rc
    [[ -s $(secret_path curseforge_api_key) ]] && key=$(read_secret curseforge_api_key)
    [[ -z $key ]] && warn "secrets/curseforge_api_key is empty: the CurseForge source will not work until you set it (./ptero key set curseforge) and re-run egg install"
    CF_KEY_TMP=$key python3 "$PTERO_ROOT/lib/egg_build.py" --key-from-env CF_KEY_TMP --out "$json" || { err "egg build failed"; return 1; }
    cat >"$php" <<'PHP'
<?php
use Illuminate\Http\UploadedFile;
use Pterodactyl\Contracts\Eggs\ImportsEggs;
use Pterodactyl\Contracts\Eggs\UpdatesEggsFromImports;
use Pterodactyl\Models\Egg;

$source = '/tmp/ptero-egg.json';
$data = json_decode(file_get_contents($source), true, 512, JSON_THROW_ON_ERROR);
$egg = Egg::query()->where('name', $data['name'])->first();
if ($egg) {
    // an update must not wipe a CurseForge key the administrator already stored
    $existing = $egg->variables()->where('env_variable', 'CURSEFORGE_API_KEY')->value('default_value');
    foreach ($data['variables'] as &$v) {
        if ($v['env_variable'] === 'CURSEFORGE_API_KEY' && $v['default_value'] === '' && $existing) {
            $v['default_value'] = $existing;
        }
    }
    unset($v);
}
$path = tempnam(sys_get_temp_dir(), 'egg');
if (file_put_contents($path, json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)) === false) {
    fwrite(STDERR, "cannot write the import file\n");
    exit(1);
}
chmod($path, 0600);
$file = new UploadedFile($path, 'egg.json', 'application/json', null, true);
if ($egg) {
    app(UpdatesEggsFromImports::class)->update($egg, $file);
    echo "egg updated: id {$egg->id}\n";
} else {
    $new = app(ImportsEggs::class)->import($file);
    echo "egg imported: id {$new->id}\n";
}
@unlink($path);
@unlink($source);
PHP
    # streamed through stdin (not `docker cp`): the files must belong to the user that runs PHP, or they could not be removed afterwards
    compose exec -T panel sh -c 'umask 077; cat >/tmp/ptero-egg.json' <"$json" || { err "cannot hand the egg to the Panel container"; return 1; }
    compose exec -T panel sh -c 'umask 077; cat >/tmp/ptero-egg-import.php' <"$php" || { err "cannot hand the import script to the Panel container"; return 1; }
    out=$(compose exec -T panel php artisan tinker --execute="require '/tmp/ptero-egg-import.php';" 2>&1); rc=$?
    compose exec -T panel rm -f /tmp/ptero-egg.json /tmp/ptero-egg-import.php >/dev/null 2>&1
    if [[ $rc -ne 0 || $out != *"egg "* ]]; then
        printf '%s\n' "$out" | redact | tail -n 15 >&2
        err "importing the egg failed. Fallback: Admin -> Eggs -> Import with eggs/modpack-installer/modpack-installer.egg.json"
        return 1
    fi
    printf '%s\n' "$out" | grep -E '^egg (imported|updated)'
}

cmd_egg() {
    case ${1:-} in
        build)
            python3 "$PTERO_ROOT/lib/egg_build.py" || die "egg build failed"
            ;;
        check)
            python3 "$PTERO_ROOT/lib/egg_build.py" --check || exit $EX_FAIL
            ;;
        install)
            prepare 0
            [[ $(svc_state panel) == healthy ]] || die "the Panel is not running: ./ptero setup" $EX_REFUSED
            # a missing CurseForge key is already reported by egg_install_run (warn), so nothing else is printed here
            egg_install_run || exit $EX_FAIL
            ;;
        *) die "usage: ./ptero egg {build|check|install}" $EX_USAGE ;;
    esac
}

# ./ptero key set panel|curseforge : store an API key without it touching the shell history or a command line
cmd_key() {
    [[ ${1:-} == set ]] || die "usage: ./ptero key set {panel|curseforge|client}" $EX_USAGE
    local name label val
    case ${2:-} in
        panel) name=panel_api_key; label=Application ;;
        client) name=panel_client_key; label=Client ;;
        curseforge) name=curseforge_api_key; label=CurseForge ;;
        *) die "usage: ./ptero key set {panel|curseforge|client}" $EX_USAGE ;;
    esac
    mkdir_private "$PTERO_ROOT/secrets" || die "cannot create secrets/"
    val=$(read_hidden "Paste the $label API key (input hidden): ")
    val=${val//[[:space:]]/}
    [[ -n $val ]] || die "empty key" $EX_USAGE
    if [[ $name == panel_api_key && ! $val =~ ^ptla_[A-Za-z0-9]{20,}$ ]]; then
        die "that is not a Panel Application API key (it starts with ptla_). Create it in Admin -> Application API" $EX_USAGE
    fi
    [[ $name == panel_client_key && ! $val =~ ^ptlc_[A-Za-z0-9]{20,}$ ]] && die "that is not a Panel Client API key (it starts with ptlc_). Create it in Account -> API Credentials" $EX_USAGE
    [[ $name == curseforge_api_key && ! $val =~ ^[A-Za-z0-9\$./_-]{20,}$ ]] && die "that does not look like a CurseForge API key" $EX_USAGE
    write_secret "$(secret_path "$name")" "$val" || die "cannot write secrets/$name"
    info "saved secrets/$name (mode 600)"
}
