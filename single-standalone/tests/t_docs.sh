#!/usr/bin/env bash
# Task 22: the documentation set matches the code. Reads files only (grep, sed, awk); runs no mcctl and no Docker.
# The checker is the set of check_* functions below. It runs on the real tree and, against tests/fixtures/docs-broken, which holds one
# instance of each fault it must report (the fixture must fail for every rule, or the rule is not known to work).
# Pages checked: README.md and docs/*.md at the top level. docs/itzg/ is the itzg image's documentation and is not checked.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOCS=$REPO/docs
REF=$DOCS/reference.md
ARCH=$DOCS/architecture.md
TS=$DOCS/troubleshooting.md
FX=$REPO/tests/fixtures/docs-broken

# ---- the checker -----------------------------------------------------------------------------------------------------------------

# md_pages ROOT: README.md and docs/*.md (top level only)
md_pages() {
    [[ -f $1/README.md ]] && printf '%s\n' "$1/README.md"
    local f
    for f in "$1"/docs/*.md; do [[ -f $f ]] && printf '%s\n' "$f"; done
    return 0
}

# md_slugs FILE: the anchor of every heading outside code fences (lower case; a-z 0-9 space _ - kept; spaces become -)
md_slugs() {
    awk '/^```/ { f = !f; next } !f && /^#+ / { sub(/^#+ +/, ""); print }' "$1" \
        | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9 _-]//g' -e 's/ /-/g'
}

# md_links FILE: "LINE<TAB>TARGET" for each Markdown link outside code fences
md_links() {
    awk '
        /^```/ { f = !f; next }
        f { next }
        {
            s = $0
            while (match(s, /\]\([^)]*\)/)) {
                print NR "\t" substr(s, RSTART + 2, RLENGTH - 3)
                s = substr(s, RSTART + RLENGTH)
            }
        }' "$1"
}

# check_links ROOT: every relative link of a page names a file that exists; every #anchor names a heading of that file
check_links() {
    local r=$1 page n t path anchor target
    while IFS= read -r page; do
        while IFS=$'\t' read -r n t; do
            case $t in ""|http://*|https://*|mailto:*) continue ;; esac
            path=${t%%#*} anchor=""
            [[ $t == *'#'* ]] && anchor=${t#*#}
            target=$page
            [[ -z $path ]] || target=$(dirname -- "$page")/$path
            if [[ ! -f $target ]]; then
                printf 'BROKEN LINK %s:%s -> %s\n' "${page#"$r"/}" "$n" "$t"
            elif [[ -n $anchor && $target == *.md ]] && ! md_slugs "$target" | grep -qxF -- "$anchor"; then
                printf 'BROKEN ANCHOR %s:%s -> %s\n' "${page#"$r"/}" "$n" "$t"
            fi
        done < <(md_links "$page")
    done < <(md_pages "$r")
}

# check_index ROOT: docs/README.md links every other top-level page of docs/
check_index() {
    local r=$1 f b
    [[ -f $r/docs/README.md ]] || { printf 'MISSING docs/README.md\n'; return 0; }
    for f in "$r"/docs/*.md; do
        [[ -f $f ]] || continue
        b=${f##*/}
        [[ $b == README.md ]] && continue
        md_links "$r/docs/README.md" | cut -f2 | sed -e 's/#.*//' -e 's|^\./||' | grep -qxF -- "$b" \
            || printf 'NOT INDEXED docs/%s (docs/README.md has no link to it)\n' "$b"
    done
}

# check_commands ROOT: every cmd_* function in lib/ has a "## mcctl" section in docs/reference.md (a heading may name several
# commands, separated by commas or "and"; a name with a suffix, as in "whitelist list --names", counts for its first word)
check_commands() {
    local r=$1 fn c names
    names=$(sed -n 's/^## mcctl //p' "$r/docs/reference.md" 2>/dev/null | sed -e 's/ and /, /g' | tr ',' '\n' \
        | sed -e 's/^ *//' -e 's/ *$//')
    while IFS= read -r fn; do
        c=${fn#cmd_}; c=${c//_/-}
        grep -qxF -- "$c" <<<"$names" || grep -q -- "^$c " <<<"$names" \
            || printf 'NO SECTION mcctl %s (%s in lib/)\n' "$c" "$fn"
    done < <(grep -hoE '^cmd_[a-z_0-9]+' "$r"/lib/*.sh | sort -u)
}

# check_messages ROOT FILE: every `fragment` in the first column of a table row of FILE occurs verbatim in lib/ or in mcctl
check_messages() {
    local r=$1 f=$2 frag
    while IFS= read -r frag; do
        [[ -n $frag ]] || continue
        grep -rqF -e "$frag" "$r/lib" "$r/mcctl" 2>/dev/null \
            || printf 'STALE MESSAGE %s: `%s` is in no file under lib/ or mcctl\n' "${f#"$r"/}" "$frag"
    done < <(awk -F'|' '/^\|/ && !/^\|[-|: ]+\|$/ { print $2 }' "$f" | grep -oE '`[^`]+`' | tr -d '`')
}

# md_mermaid FILE HEADING: the first ```mermaid block under "## HEADING"
md_mermaid() {
    awk -v h="$2" '
        $0 == "## " h { sec = 1; next }
        sec && /^## / { exit }
        sec && /^```mermaid/ { blk = 1; next }
        blk && /^```/ { exit }
        blk { print }' "$1"
}

# in_order TEXT PHRASE...: every PHRASE occurs in TEXT, in the order given. On failure prints the first PHRASE not found and returns 1.
in_order() {
    local text=$1 p
    shift
    for p in "$@"; do
        [[ $text == *"$p"* ]] || { printf '%s' "$p"; return 1; }
        text=${text#*"$p"}
    done
}

# expect_none LABEL OUTPUT: pass when OUTPUT is empty, else fail and show it on one line (fail() shows at most 8 lines)
expect_none() { if [[ -z $2 ]]; then pass "$1"; else fail "$1" "$(printf '%s' "$2" | tr '\n' ';' | sed 's/;$//')"; fi; }

# ---- the real tree ---------------------------------------------------------------------------------------------------------------

expect_none "every relative link in README.md and docs/*.md resolves, and every #anchor matches a heading" "$(check_links "$REPO")"
expect_none "docs/README.md links every page in docs/" "$(check_index "$REPO")"
expect_none "every cmd_* in lib/ has a ## mcctl section in docs/reference.md" "$(check_commands "$REPO")"

miss=""
for n in $(grep -rhoE 'MCCTL_[A-Z0-9_]+' "$REPO/lib" "$REPO/templates" "$REPO/config/mcctl.env.example" | sort -u); do
    grep -qF -- "$n" "$REF" || miss+="$n "
done
expect_none "every MCCTL_* name under lib/, templates/ and config/mcctl.env.example appears in reference.md" \
    "${miss:+missing: $miss}"

keys=$(awk '/^declare -A SETTING_TYPE=\(/ { f = 1; next } f && /^\)/ { exit } f' "$REPO/lib/settings.sh" \
    | grep -oE '\[[A-Z0-9_]+\]=' | tr -d '[]=')
sec=$(awk '/^## mcctl set, get, unset, env, apply$/ { f = 1; print; next } f && /^## / { exit } f' "$REF" 2>/dev/null)
miss=""
for k in $keys; do printf '%s\n' "$sec" | grep -qw -- "$k" || miss+="$k "; done
expect_none "every key of settings_type appears in the settings table of reference.md" "${miss:+missing: $miss}"

SENT="The Cloudflare record for the game port is DNS-only (grey cloud); the origin IP is reachable directly, because Cloudflare's free plan cannot proxy raw Minecraft traffic. This is a protocol limit, not a defect; the firewall, the egress guard and the rate limit are what protect that address."
if grep -qF -- "$SENT" "$DOCS/prerequisites.md" 2>/dev/null; then pass "prerequisites.md states the game-port DNS sentence verbatim"
else fail "prerequisites.md states the game-port DNS sentence verbatim" "not found in docs/prerequisites.md"; fi

n=$(grep -c '^```mermaid$' "$ARCH" 2>/dev/null)
if ((${n:-0} >= 5)); then pass "architecture.md has $n mermaid blocks (at least 5)"
else fail "architecture.md has ${n:-0} mermaid blocks (at least 5)"; fi

# the step words of each diagram, in the order the code runs them (architecture.md section 4.2)
declare -A STEPS=(
    [create]="validate flags|server_exists|cf_create_record|RCON secret|config files|write_compose|sftp_add_user|compose create|router_reload|_create_undo"
    [delete]="confirm|dc stop|tar -tzf|_delete_dns|rm -s -f|router_reload|_remove_files"
    [backup restore]="while running|tar -tzf|unsafe members|confirm|data.pre-restore|extract|report both paths"
    [world restore]="while running|tar -tzf|safety|confirm|extract"
    [router and egress]="Internet|DNAT|DOCKER-USER|MCCTL-INGRESS|mc-router|game containers|INPUT"
    [drift]="pending|config_hash|apply|_recreate_guard|_recreate_apply|force-recreate"
)
for h in "${!STEPS[@]}"; do
    IFS='|' read -ra ph <<<"${STEPS[$h]}"
    blk=$(md_mermaid "$ARCH" "$h")
    if miss=$(in_order "$blk" "${ph[@]}"); then pass "architecture.md $h: the steps are in order"
    else fail "architecture.md $h: the step '$miss' is missing or out of order (in the mermaid block under ## $h)"; fi
done

rows=$(( $(grep -c '^|' "$TS" 2>/dev/null) - 2 ))
if ((rows >= 40)); then pass "troubleshooting.md has $rows table rows (at least 40)"
else fail "troubleshooting.md has $rows table rows (at least 40)"; fi
expect_none "every quoted message in the troubleshooting symptom column occurs verbatim under lib/ or in mcctl" \
    "$(check_messages "$REPO" "$TS")"

first=$(awk 'BEGIN { RS = "" } !/^#/ { print; exit }' "$REPO/README.md" 2>/dev/null)
if [[ $first == *"docs/itzg/"* && $first == *differ* ]]; then pass "README.md first paragraph names docs/itzg/ and says the two folders differ"
else fail "README.md first paragraph names docs/itzg/ and says the two folders differ" "${first:0:200}"; fi

if grep -qF -- "no script manages" "$DOCS/velocity.md" 2>/dev/null; then pass "velocity.md says no script manages Velocity"
else fail "velocity.md says no script manages Velocity"; fi

ACC=$DOCS/acceptance.md
if [[ -e $ACC ]]; then
    miss=""
    for n in $(seq 1 22); do grep -q "^### Step $n:" "$ACC" || miss+="$n "; done
    expect_none "acceptance.md has one section per Task 23 step (1 to 22)" "${miss:+missing: $miss}"
    # five-column tables (Date, Host, Commands, Result, Notes): the Result cell of every data row is empty
    filled=$(awk -F'|' '/^\|/ && NF == 7 && $2 !~ /Date and time/ && $2 !~ /^ *-+ *$/ && $5 ~ /[^ ]/' "$ACC" | wc -l)
    if ((filled == 0)); then pass "acceptance.md result cells are all empty"
    else fail "acceptance.md result cells are all empty" "$filled rows have a result"; fi
else
    skip "acceptance.md is written by Task 23 (not yet present): its step sections are not checked"
fi

MG=$DOCS/management-guide.md
for h in "Worlds" "Settings and drift" "Files" "Players" "Mods, plugins and Modrinth" "Versions and loaders" "Modpacks" \
    "Clone, rename, export and import"; do
    if grep -qxF -- "## $h" "$MG" 2>/dev/null; then pass "management-guide.md has the section '$h'"
    else fail "management-guide.md has the section '$h'"; fi
done
cmds=$(grep -hoE '^cmd_[a-z_0-9]+' "$REPO"/lib/*.sh | sed -e 's/^cmd_//' -e 's/_/-/g'; echo help; echo version)
miss=""
for c in $(grep -oE 'mcctl [a-z][a-z-]*' "$MG" 2>/dev/null | cut -d' ' -f2 | sort -u); do
    grep -qxF -- "$c" <<<"$cmds" || miss+="$c "
done
expect_none "every mcctl command the management guide shows is in mcctl's dispatch table" "${miss:+unknown: $miss}"

# ---- the checker, on the fixture: each fault is reported ----------------------------------------------------------------------

out=$(check_links "$FX"; check_index "$FX"; check_commands "$FX"; check_messages "$FX" "$FX/docs/troubleshooting.md")
assert_contains "$out" "BROKEN LINK docs/page.md:3 -> nope.md" "fixture: a broken link is reported"
assert_contains "$out" "BROKEN ANCHOR docs/page.md:5 -> reference.md#no-such-heading" "fixture: a broken anchor is reported"
assert_contains "$out" "NOT INDEXED docs/orphan.md" "fixture: a page missing from docs/README.md is reported"
assert_contains "$out" "NO SECTION mcctl frob" "fixture: a command with no reference section is reported"
assert_contains "$out" 'STALE MESSAGE docs/troubleshooting.md: `fixture message that was reworded`' "fixture: a stale message fragment is reported"
assert_not_contains "$out" "docs/page.md:4" "fixture: a valid link and anchor are not reported"
assert_not_contains "$out" "fixture says hello" "fixture: a fragment that is in lib/ is not reported"

# ---- no new eval, sudo or Python in the code this task adds (the words are spelled apart here so this file does not name them)
kws=("ev""al" "su""do" "py""thon" "py""thon""3")
for w in "${kws[@]}"; do
    hits=$(scan_word "$w" "$REPO/tests/t_docs.sh" "$FX"/lib/*.sh)
    expect_none "no $w in tests/t_docs.sh or the fixture code" "$hits"
done

finish
