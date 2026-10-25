#!/usr/bin/env bash
# E6: property test. 300 inputs built from lower-case letters, digits, space, tab, newline, '/', '.', '..' and the shell and
# compose metacharacters, generated with RANDOM=20261024 (the same 300 every run). Each input goes through each validator in a
# subshell. A run passes when it exits 0 with the property below holding, or refuses. A validator that answers yes/no
# (valid_server_name) refuses with 1; a function that complains (compose_escape, safe_path ...) refuses with 2. Any other exit
# code, and any property that breaks, fails the test. Each function gets a `check_` property below and a `run_prop` line at the end.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$REPO/lib/common.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/compose.sh"
source "$REPO/lib/mods.sh"
source "$REPO/lib/modpack.sh"
source "$REPO/lib/rcon.sh"
source "$REPO/lib/players.sh"
source "$REPO/lib/data.sh"
source "$REPO/lib/worlds.sh"
sandbox
export MCCTL_DOMAIN=mc.example.net
load_config 2>/dev/null

# -- the inputs
TOKENS=(a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9
        ' ' $'\t' $'\n' / . .. '$' "'" '"' '\' ';' '|' '&' '`' '(' ')' '*' '?' '[' ']' '{' '}' '%' '#' '!')
INPUTS=()
RANDOM=20261024
for ((i = 0; i < 300; i++)); do
    len=$((RANDOM % 10)); s=""
    for ((j = 0; j < len; j++)); do s+=${TOKENS[RANDOM % ${#TOKENS[@]}]}; done
    INPUTS+=("$s")
done
assert_eq 300 "${#INPUTS[@]}" "300 inputs generated"
distinct=$(printf '%s\0' "${INPUTS[@]}" | sort -zu | tr -cd '\0' | wc -c)
((distinct >= 250)) && pass "and they are varied ($distinct distinct)" || fail "and they are varied" "only $distinct distinct"

# -- the properties. Each takes INPUT STATUS STDOUT and prints a reason when the run breaks the property.
LC_ALL=C
check_valid_server_name() { # accepted names are 1 to 40 of [a-z0-9-], not starting with '-'
    case $2 in
        0) [[ -n $1 && ${#1} -le 40 && $1 != -* && -z ${1//[a-z0-9-]/} ]] || echo "accepted a name outside [a-z0-9-]{1,40}" ;;
        1) ;;
        *) echo "exit $2 (a yes/no validator may only exit 0 or 1)" ;;
    esac
}
check_slugify() { # always exit 0; output is empty or a valid server name, one line, no '-' at either end
    [[ $2 == 0 ]] || { echo "exit $2"; return; }
    local o=$3
    [[ -z $o ]] && return
    [[ ${#o} -le 40 && $o != -* && $o != *- && $o != *--* && -z ${o//[a-z0-9-]/} ]] || echo "slug ${o@Q} is not [a-z0-9-], 1 to 40, without edge or doubled '-'"
    valid_server_name "$o" || echo "slug ${o@Q} is not a valid server name"
}
decode_escaped() { # inverse of compose_escape; fails on a bare '"', a lone '\' or a lone '$'
    local s=$1 out="" c n i=0 len=${#1}
    while ((i < len)); do
        c=${s:i:1}; n=${s:i+1:1}
        case $c in
            '\') [[ $n == '\' || $n == '"' ]] || return 1; out+=$n; i=$((i + 2)) ;;
            '$') [[ $n == '$' ]] || return 1; out+='$'; i=$((i + 2)) ;;
            '"') return 1 ;;
            *) out+=$c; i=$((i + 1)) ;;
        esac
    done
    printf '%s' "$out"
}
check_compose_escape() { # refuses (2, no output) exactly the inputs with a control character other than a tab; else round-trips
    local ctl=${1//$'\t'/} back
    if [[ $ctl == *[[:cntrl:]]* ]]; then
        [[ $2 == 2 && -z $3 ]] || echo "a control character was not refused with exit 2 and no output (exit $2)"
    else
        [[ $2 == 0 ]] || { echo "refused a harmless input (exit $2)"; return; }
        back=$(decode_escaped "$3") || { echo "output ${3@Q} has a bare \", a lone \\ or a lone \$"; return; }
        [[ $back == "$1" ]] || echo "output ${3@Q} does not decode back to the input"
    fi
}
check_valid_player() { # yes/no both ways: accepted exactly when the input is 1 to 16 of [.A-Za-z0-9_] (Task 5)
    local ok=0
    [[ -n $1 && ${#1} -le 16 && -z ${1//[.A-Za-z0-9_]/} ]] && ok=1
    case $2 in
        0) ((ok)) || echo "accepted a name that is not 1 to 16 of [.A-Za-z0-9_]" ;;
        1) ((!ok)) || echo "refused a valid player name" ;;
        *) echo "exit $2 (a yes/no validator may only exit 0 or 1)" ;;
    esac
}
rcon_text() { check_rcon_words "$1"; }   # one word as the whole command (Task 5)
check_rcon_text() { # prints nothing; accepted exactly when the word is not empty, has no control character and no leading '-'
    local ok=0
    [[ -n $1 && $1 != -* && ${1//[$'\001'-$'\037'$'\177']/} == "$1" ]] && ok=1
    [[ -z $3 ]] || { echo "printed ${3@Q} on stdout"; return; }
    case $2 in
        0) ((ok)) || echo "accepted an empty word, a leading '-' or a control character" ;;
        2) ((!ok)) || echo "refused a harmless word" ;;
        *) echo "exit $2 (check_rcon_words may only exit 0 or 2)" ;;
    esac
}
# modpack_env (Task 4): four wrappers put the input in each slot of each source; one property serves all four. An accepted run
# prints KEY=VALUE lines whose values hold only [A-Za-z0-9._+-], and the input is the value of its slot; a refused one exits 2 and
# prints nothing. An id slot refuses an empty input and, for CurseForge, an all-digit one; a version slot accepts an empty input.
mp_cf_id()  { modpack_env curseforge "$1"; }
mp_mr_id()  { modpack_env modrinth "$1"; }
mp_cf_ver() { modpack_env curseforge a-pack "$1"; }
mp_mr_ver() { modpack_env modrinth a-pack "$1"; }
check_mp() { # INPUT STATUS STDOUT SLOT-KEY RE-OF-A-VALID-INPUT
    local line
    case $2 in
        2) [[ -z $3 ]] || echo "refused (exit 2) but printed ${3@Q}"; return ;;
        0) ;;
        *) echo "exit $2 (modpack_env may only exit 0 or 2)"; return ;;
    esac
    while IFS= read -r line; do
        [[ $line =~ ^[A-Z][A-Z0-9_]*=[A-Za-z0-9._+-]*$ ]] || { echo "line ${line@Q} is not KEY=VALUE of safe characters"; return; }
    done <<<"$3"
    [[ -n $1 ]] || { [[ $4 == *_VERSION || $4 == CF_FILE_ID ]] && return; echo "accepted an empty id"; return; }
    [[ $1 =~ $5 ]] || echo "accepted ${1@Q}, which is not a valid value for $4"
    [[ $3 == *$'\n'"$4=$1" || $3 == "$4=$1" ]] || echo "$4=${1@Q} is not in the output ${3@Q}"
}
check_mp_cf_id()  { check_mp "$1" "$2" "$3" CF_SLUG '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'; [[ $2 != 0 || ! $1 =~ ^[0-9]+$ ]] || echo "accepted the number $1 as a CurseForge slug"; }
check_mp_mr_id()  { check_mp "$1" "$2" "$3" MODRINTH_MODPACK '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'; }
check_mp_cf_ver() { check_mp "$1" "$2" "$3" CF_FILE_ID '^[0-9]{1,12}$'; }
check_mp_mr_ver() { check_mp "$1" "$2" "$3" MODRINTH_VERSION '^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$'; }

# run_prop FN: run FN on every input in a subshell and collect the broken properties. Sets RUN_ACCEPT and RUN_REFUSE.
run_prop() {
    local fn=$1 in out rc why bad=0 first=""
    RUN_ACCEPT=0 RUN_REFUSE=0
    for in in "${INPUTS[@]}"; do
        out=$( ( "$fn" "$in" ) 2>/dev/null; echo "rc=$?" )   # the status travels as the last line; $( ) strips only the final newline
        rc=${out##*rc=}; out=${out%rc=*}; out=${out%$'\n'}
        why=$("check_$fn" "$in" "$rc" "$out")
        [[ $rc == 0 ]] && RUN_ACCEPT=$((RUN_ACCEPT + 1)) || RUN_REFUSE=$((RUN_REFUSE + 1))
        if [[ -n $why ]]; then bad=$((bad + 1)); [[ -n $first ]] || first="input ${in@Q}: $why"; fi
    done
    RUN_BAD=$bad RUN_FIRST=$first
}

# block_escape and valid_modrinth_entry (Task 20): block_escape refuses exactly the control characters (a tab too) and doubles each $;
# a Modrinth entry is a slug of 1 to 64 of [a-z0-9_-], optionally ':' and a version of 1 to 64 of [A-Za-z0-9._-]
check_block_escape() {
    local want=${1//'$'/'$$'}
    if [[ $1 == *[[:cntrl:]]* ]]; then
        [[ $2 == 2 && -z $3 ]] || echo "a control character was not refused with exit 2 and no output (exit $2)"
    else
        [[ $2 == 0 ]] || { echo "refused a harmless input (exit $2)"; return; }
        [[ $3 == "$want" ]] || echo "output ${3@Q} is not the input with each \$ doubled"
    fi
}
check_valid_modrinth_entry() {
    local e=$1 ok=0 slug=$1 ver=""
    if [[ $e == *:* ]]; then slug=${e%%:*}; ver=${e#*:}; fi
    if [[ -n $slug && ${#slug} -le 64 && -z ${slug//[a-z0-9_-]/} ]]; then
        if [[ $e != *:* ]] || [[ -n $ver && ${#ver} -le 64 && -z ${ver//[A-Za-z0-9._-]/} ]]; then ok=1; fi
    fi
    case $2 in
        0) ((ok)) || echo "accepted ${1@Q}, which is not a slug[:version]" ;;
        1) ((!ok)) || echo "refused ${1@Q}, which is a slug[:version]" ;;
        *) echo "exit $2 (valid_modrinth_entry may only exit 0 or 1)" ;;
    esac
    [[ -z $3 ]] || echo "printed ${3@Q} on stdout"
}
# valid_mod_entry: accepted exactly when the entry is an https:// URL with a host part and no '@' in it, or a container path under
# /mods/ or /plugins/ with no '..' component; 1 to 500 printable characters, none of them a quote, a backtick, '$' or a backslash
check_valid_mod_entry() {
    local e=$1 want=0 p
    local -a parts
    if ((${#e} >= 1 && ${#e} <= 500)) && [[ $e =~ ^[!-~]+$ && -z ${e//[^\"\'\`\$\\]/} ]]; then
        if [[ $e =~ ^https://[^/@]+(/|$) ]]; then want=1
        elif [[ $e =~ ^/(mods|plugins)/. ]]; then
            IFS=/ read -r -a parts <<<"$e"
            want=1
            for p in "${parts[@]}"; do [[ $p != .. ]] || want=0; done
        fi
    fi
    case $2 in
        0) ((want)) || echo "accepted ${1@Q}, which the rule refuses" ;;
        1) ((!want)) || echo "refused ${1@Q}, which the rule accepts" ;;
        *) echo "exit $2 (valid_mod_entry may only exit 0 or 1)" ;;
    esac
    [[ -z $3 ]] || echo "printed ${3@Q} on stdout"
}

# safe_path (Task 15): exit 0 or 2 only. Accepted exactly when the input is not empty, has no control character, is not absolute and
# has no '..' component. An accepted output is one non-empty line, not absolute, has no '..' component, and is stable: safe_path of it is itself.
check_safe_path() {
    local want=0 out2
    if [[ -n $1 && $1 != *[[:cntrl:]]* && $1 != /* && $1 != .. && $1 != ../* && $1 != */.. && $1 != */../* ]]; then want=1; fi
    case $2 in
        0) ((want)) || { echo "accepted ${1@Q}, which is empty, absolute, has a control character or a '..' component"; return; }
           [[ -n $3 && $3 != *$'\n'* && $3 != /* && $3 != .. && $3 != ../* && $3 != */.. && $3 != */../* ]] || { echo "output ${3@Q} is empty, not one line, absolute or has a '..' component"; return; }
           out2=$(safe_path "$3" 2>/dev/null) && [[ $out2 == "$3" ]] || echo "output ${3@Q} is not stable: safe_path of it gives ${out2@Q}" ;;
        2) ((want)) && echo "refused ${1@Q}, which the rule accepts"
           [[ -z $3 ]] || echo "printed ${3@Q} on a refusal" ;;
        *) echo "exit $2 (safe_path may only exit 0 or 2)" ;;
    esac
}
# valid_world_name (Task 16): yes/no both ways. Accepted exactly when the input is 1 to 64 of [A-Za-z0-9_.-] starting with a letter or
# digit, is not a folder the server uses, and is not a Paper sibling (*_nether, *_the_end).
check_valid_world_name() {
    local ok=0 re='^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'
    [[ $1 =~ $re ]] && ok=1
    case $1 in
        plugins|mods|config|logs|libraries|versions|cache|crash-reports|defaultconfigs|resourcepacks|datapacks|backups|*_nether|*_the_end) ok=0 ;;
    esac
    case $2 in
        0) ((ok)) || echo "accepted ${1@Q}, which is not a world name" ;;
        1) ((!ok)) || echo "refused ${1@Q}, which is a world name" ;;
        *) echo "exit $2 (valid_world_name may only exit 0 or 1)" ;;
    esac
    [[ -z $3 ]] || echo "printed ${3@Q} on stdout"
}

for fn in valid_server_name slugify compose_escape valid_player rcon_text mp_cf_id mp_mr_id mp_cf_ver mp_mr_ver block_escape valid_modrinth_entry; do
    echo "$fn"
    run_prop "$fn"
    assert_eq 0 "$RUN_BAD" "$fn: all 300 inputs behave ${RUN_FIRST:+(first failure: $RUN_FIRST)}"
    if [[ $fn != slugify ]]; then
        ((RUN_ACCEPT >= 10 && RUN_REFUSE >= 10)) && pass "$fn: the inputs reach both outcomes ($RUN_ACCEPT accepted, $RUN_REFUSE refused)" \
            || fail "$fn: the inputs reach both outcomes" "$RUN_ACCEPT accepted, $RUN_REFUSE refused"
    fi
done

# -- valid_ip and valid_runtime_arg (Task 17): exit 0 or 2 only, nothing on stdout. say and reason accept only text with no control
# character, within their limit (256 and 100 bytes). Plain calls, not subshells: 3600 of them.
echo "valid_ip and valid_runtime_arg"
bad=0 first="" acc=0 ref=0
for in in "${INPUTS[@]}"; do
    valid_ip "$in" >"$SB/fz.out" 2>/dev/null; rc=$?
    if [[ ($rc != 0 && $rc != 2) || -s $SB/fz.out ]]; then bad=$((bad + 1)); first=${first:-"valid_ip ${in@Q}"}; fi
done
for kind in say reason rule rule_value time weather difficulty gamemode seconds border border_seconds center; do
    lim=0; case $kind in say) lim=256 ;; reason) lim=100 ;; esac
    for in in "${INPUTS[@]}"; do
        valid_runtime_arg "$kind" "$in" >"$SB/fz.out" 2>/dev/null; rc=$?
        ok=1
        [[ ($rc == 0 || $rc == 2) && ! -s $SB/fz.out ]] || ok=0
        if ((lim)) && [[ $rc == 0 ]] && { [[ -z $in || $in == *[[:cntrl:]]* ]] || ((${#in} > lim)); }; then ok=0; fi
        ((ok)) || { bad=$((bad + 1)); first=${first:-"$kind ${in@Q}"}; }
        if [[ $rc == 0 ]]; then acc=$((acc + 1)); else ref=$((ref + 1)); fi
    done
done
assert_eq 0 "$bad" "valid_ip, and valid_runtime_arg for 12 kinds, on all 300 inputs ${first:+(first failure: $first)}"
((acc >= 10 && ref >= 10)) && pass "valid_runtime_arg: the inputs reach both outcomes ($acc accepted, $ref refused)" \
    || fail "valid_runtime_arg: the inputs reach both outcomes" "$acc accepted, $ref refused"

# -- valid_mod_entry (Task 20): a bare random input is never a URL or a container path, so each input runs under two prefixes too. The
# prefixed inputs must reach both outcomes.
base=("${INPUTS[@]}"); INPUTS=()
for s in "${base[@]}"; do INPUTS+=("https://x.example/$s" "/mods/$s"); done
run_prop valid_mod_entry
assert_eq 0 "$RUN_BAD" "valid_mod_entry: all ${#INPUTS[@]} prefixed inputs behave ${RUN_FIRST:+(first failure: $RUN_FIRST)}"
((RUN_ACCEPT >= 10 && RUN_REFUSE >= 10)) && pass "valid_mod_entry: the inputs reach both outcomes ($RUN_ACCEPT accepted, $RUN_REFUSE refused)" \
    || fail "valid_mod_entry: the inputs reach both outcomes" "$RUN_ACCEPT accepted, $RUN_REFUSE refused"
INPUTS=("${base[@]}")

# -- safe_path (Task 15) and valid_world_name (Task 16). The random inputs almost never make a '..' component, so safe_path also runs
# on each input behind '../' and before '/../b'. valid_world_name also runs on each input with a 'w' in front: both outcomes occur.
base=("${INPUTS[@]}"); INPUTS=()
for s in "${base[@]}"; do INPUTS+=("$s" "../$s" "$s/../b"); done
run_prop safe_path
assert_eq 0 "$RUN_BAD" "safe_path: all ${#INPUTS[@]} inputs behave ${RUN_FIRST:+(first failure: $RUN_FIRST)}"
((RUN_ACCEPT >= 10 && RUN_REFUSE >= 10)) && pass "safe_path: the inputs reach both outcomes ($RUN_ACCEPT accepted, $RUN_REFUSE refused)" \
    || fail "safe_path: the inputs reach both outcomes" "$RUN_ACCEPT accepted, $RUN_REFUSE refused"
INPUTS=("${base[@]}")
plain=("${INPUTS[@]}"); INPUTS=()
for s in "${plain[@]}"; do INPUTS+=("$s" "w$s"); done
run_prop valid_world_name
assert_eq 0 "$RUN_BAD" "valid_world_name: all ${#INPUTS[@]} inputs behave ${RUN_FIRST:+(first failure: $RUN_FIRST)}"
((RUN_ACCEPT >= 10 && RUN_REFUSE >= 10)) && pass "valid_world_name: the inputs reach both outcomes ($RUN_ACCEPT accepted, $RUN_REFUSE refused)" \
    || fail "valid_world_name: the inputs reach both outcomes" "$RUN_ACCEPT accepted, $RUN_REFUSE refused"

sandbox_cleanup
finish
