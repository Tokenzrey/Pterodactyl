#!/usr/bin/env bash
# shellcheck shell=bash
# Live monitoring: mcctl top. Sourced by ./mcctl, never executed.
#

# _mcctl_utf8: 0/1 — is the current locale UTF-8? (cached per LC_ALL/LANG)
_mcctl_utf8() {
    local key="${LC_ALL:-}|${LANG:-}"
    if [[ ${_MCCTL_UTF8_KEY:-} != "$key" ]]; then
        _MCCTL_UTF8_KEY=$key
        if [[ $(locale charmap 2>/dev/null) == UTF-8 ]]; then _MCCTL_UTF8_CACHE=1; else _MCCTL_UTF8_CACHE=0; fi
    fi
    (( _MCCTL_UTF8_CACHE ))
}

# render_bar PCT WIDTH: stdout a filled/empty bar of WIDTH cells. PCT may have a trailing %.
# Green <60, yellow 60-84, red >=85. NO_COLOR non-empty: no ESC. UTF-8: full=█ empty=░; ASCII: # and -.
render_bar() {
    local pct=${1-} width=${2-0} int_pct filled empty color="" reset="" bar="" i fc ec
    pct=${pct%[%]}
    [[ $pct =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || pct=0
    int_pct=${pct%%.*}
    [[ $int_pct =~ ^- ]] && int_pct=0
    ((int_pct > 100)) && int_pct=100
    ((width <= 0)) && return 0
    filled=$(( (int_pct * width + 50) / 100 ))
    ((filled > width)) && filled=$width
    ((filled < 0)) && filled=0
    empty=$((width - filled))
    if [[ -z ${NO_COLOR:-} ]]; then
        if   ((int_pct < 60)); then color=$'\033[32m'
        elif ((int_pct < 85)); then color=$'\033[33m'
        else                       color=$'\033[31m'
        fi
        reset=$'\033[0m'
    fi
    if _mcctl_utf8; then fc=$'\xe2\x96\x88' ec=$'\xe2\x96\x91'; else fc='#' ec='-'; fi
    for ((i = 0; i < filled; i++)); do bar+=$fc; done
    for ((i = 0; i < empty; i++)); do bar+=$ec; done
    printf '%s%s%s' "$color" "$bar" "$reset"
}

# _pad_right S W: S truncated to W visible chars (with … or ~) and right-padded with spaces
_pad_right() {
    local s=$1 w=$2 pad
    if ((${#s} > w)); then
        if _mcctl_utf8; then s=${s:0:$((w-1))}$'\xe2\x80\xa6'; else s=${s:0:$((w-1))}~; fi
    fi
    pad=$((w - ${#s}))
    if ((pad > 0)); then printf '%s%*s' "$s" "$pad" ''; else printf '%s' "$s"; fi
}

# render_top_frame [RUNNING]: reads tab-separated lines on stdin (name, cpu%, mem_used, mem_limit, mem%, net_io, block_io),
# prints a box-drawn table. RUNNING is the number of servers whose container is running (the summary's count).
# Every line has exactly W visible chars (W = clamp(columns, 60, 140)).
render_top_frame() {
    local W content name_w=24 cpu_w mem_w net_w=0 block_w=0
    local cols=${COLUMNS:-$(tput cols 2>/dev/null)}
    [[ $cols =~ ^[0-9]+$ ]] || cols=80
    ((cols < 60)) && cols=60
    ((cols > 140)) && cols=140
    W=$cols
    content=$((W - 2))
    if ((W >= 100)); then
        cpu_w=20; mem_w=20
        local half=$((content - 68))
        net_w=$((half / 2))
        block_w=$((half - net_w))
    else
        local half=$((content - 26))
        cpu_w=$((half / 2))
        mem_w=$((half - cpu_w))
    fi

    local v tl tr bl br h
    if _mcctl_utf8; then
        v=$'\xe2\x94\x82' tl=$'\xe2\x94\x8c' tr=$'\xe2\x94\x90' bl=$'\xe2\x94\x94' br=$'\xe2\x94\x98' h=$'\xe2\x94\x80'
    else
        v='|' tl='+' tr='+' bl='+' br='+' h='-'
    fi

    local input sorted
    input=$(cat)
    sorted=$(LC_ALL=C sort <<<"$input")

    local -a names=() cpus=() mem_pcts=() net_ios=() block_ios=()
    local n_total=0 n_running=${1:-0}
    local name cpu mem_used mem_limit mem_pct net_io block_io

    while IFS=$'\t' read -r name cpu mem_used mem_limit mem_pct net_io block_io; do
        [[ -z $name ]] && continue
        names+=("$name")
        cpus+=("${cpu:--}")
        mem_pcts+=("${mem_pct:--}")
        net_ios+=("${net_io:--}")
        block_ios+=("${block_io:--}")
        n_total=$((n_total + 1))
    done <<<"$sorted"

    local tot_cpu=0.0 tot_mem=0.0
    if ((n_total > 0)); then
        tot_cpu=$(awk -F'\t' '{v=$2; sub(/%$/,"",v); if(v~/^[0-9.]+$/) s+=v} END{printf "%.1f",s}' <<<"$sorted")
        tot_mem=$(awk -F'\t' '{v=$5; sub(/%$/,"",v); if(v~/^[0-9.]+$/) s+=v} END{printf "%.1f",s}' <<<"$sorted")
    fi

    local title=" mcctl top "
    local fill=$((W - 3 - ${#title}))
    local border="$tl$h$title" i
    for ((i = 0; i < fill; i++)); do border+=$h; done
    border+=$tr
    printf '%s\n' "$border"

    local summary="servers $n_total, running $n_running, cpu ${tot_cpu}%, mem ${tot_mem}%"
    summary=$(_pad_right "$summary" "$content")
    printf '%s%s%s\n' "$v" "$summary" "$v"

    local hdr
    hdr=$(_pad_right "NAME" "$name_w")
    hdr+=" $(_pad_right "CPU" "$cpu_w")"
    hdr+=" $(_pad_right "MEM" "$mem_w")"
    if ((W >= 100)); then
        hdr+=" $(_pad_right "NET" "$net_w")"
        hdr+=" $(_pad_right "BLOCK" "$block_w")"
    fi
    printf '%s%s%s\n' "$v" "$hdr" "$v"

    local r cpu_bar_w mem_bar_w cpu_text mem_text name_field net_field block_field cpu_num mem_num
    # a value cell is 8 wide and a space follows it: the bar takes the rest of the cell (cpu_w, mem_w)
    cpu_bar_w=$((cpu_w - 9))
    mem_bar_w=$((mem_w - 9))
    for ((r = 0; r < n_total; r++)); do
        name_field=$(_pad_right "${names[r]}" "$name_w")
        if [[ ${cpus[r]} == "-" ]]; then
            cpu_text="$(_pad_right "-" 8) $(render_bar 0 "$cpu_bar_w")"
        else
            cpu_num=${cpus[r]%[%]}
            cpu_text="$(_pad_right "${cpus[r]}" 8) $(render_bar "$cpu_num" "$cpu_bar_w")"
        fi
        if [[ ${mem_pcts[r]} == "-" ]]; then
            mem_text="$(_pad_right "-" 8) $(render_bar 0 "$mem_bar_w")"
        else
            mem_num=${mem_pcts[r]%[%]}
            mem_text="$(_pad_right "${mem_pcts[r]}" 8) $(render_bar "$mem_num" "$mem_bar_w")"
        fi
        local row="$name_field $cpu_text $mem_text"
        if ((W >= 100)); then
            net_field=$(_pad_right "${net_ios[r]}" "$net_w")
            block_field=$(_pad_right "${block_ios[r]}" "$block_w")
            row+=" $net_field $block_field"
        fi
        printf '%s%s%s\n' "$v" "$row" "$v"
    done

    name_field=$(_pad_right "total" "$name_w")
    cpu_text="$(_pad_right "${tot_cpu}%" 8) $(render_bar "$tot_cpu" "$cpu_bar_w")"
    mem_text="$(_pad_right "${tot_mem}%" 8) $(render_bar "$tot_mem" "$mem_bar_w")"
    local row="$name_field $cpu_text $mem_text"
    if ((W >= 100)); then
        net_field=$(_pad_right "-" "$net_w")
        block_field=$(_pad_right "-" "$block_w")
        row+=" $net_field $block_field"
    fi
    printf '%s%s%s\n' "$v" "$row" "$v"

    border="$bl"
    for ((i = 0; i < content; i++)); do border+=$h; done
    border+=$br
    printf '%s\n' "$border"
}

# _top_one_frame [NAME]: gather data from Docker and print one frame
_top_one_frame() {
    local name=${1-}
    local server_list sorted_servers
    server_list=$(docker ps -a --filter label=mcctl.managed=true \
        --format '{{.Label "mcctl.name"}}|{{.State}}|{{.Label "mc-router.host"}}|{{.Status}}') \
        || die "cannot ask Docker ('docker ps' failed): is the daemon running, and may this user use it?"
    if [[ -n $name ]]; then
        server_list=$(grep "^$name|" <<<"$server_list")
    fi
    sorted_servers=$(LC_ALL=C sort <<<"$server_list")

    local -a running_containers=()
    local sname sstate rest
    while IFS='|' read -r sname sstate rest; do
        [[ -z $sname ]] && continue
        if [[ $sstate == running ]]; then
            running_containers+=("mc-$sname")
        fi
    done <<<"$sorted_servers"

    local stats="" stats_failed=0
    if ((${#running_containers[@]} > 0)); then
        stats=$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}' "${running_containers[@]}") || stats_failed=1
    fi

    local frame_input=""
    local cname cpu mem_usage_pct mem_pct net_io block_io mem_used mem_limit found stats_line
    while IFS='|' read -r sname sstate rest; do
        [[ -z $sname ]] && continue
        if [[ $sstate == running ]]; then
            cname="mc-$sname"
            found=""
            while IFS= read -r stats_line; do
                if [[ "${stats_line%%|*}" == "$cname" ]]; then
                    found=$stats_line
                    break
                fi
            done <<<"$stats"
            if [[ -n $found ]]; then
                IFS='|' read -r _ cpu mem_usage_pct mem_pct net_io block_io <<<"$found"
                mem_used=${mem_usage_pct%% / *}
                mem_limit=${mem_usage_pct##* / }
            else
                cpu="-" mem_used="-" mem_limit="-" mem_pct="-" net_io="-" block_io="-"
            fi
        else
            cpu="-" mem_used="-" mem_limit="-" mem_pct="-" net_io="-" block_io="-"
        fi
        frame_input+="$sname"$'\t'"$cpu"$'\t'"$mem_used"$'\t'"$mem_limit"$'\t'"$mem_pct"$'\t'"$net_io"$'\t'"$block_io"$'\n'
    done <<<"$sorted_servers"

    render_top_frame "${#running_containers[@]}" <<<"$frame_input"

    if ((stats_failed)); then
        printf 'note: docker stats failed; showing - for running servers\n'
    fi
}

# cmd_top [NAME]: live monitoring table
cmd_top() {
    local usage="usage: mcctl top [NAME]"
    local name=""

    if (($# > 1)); then die "$usage" "$EX_USAGE"; fi
    if (($# == 1)); then name=$1; _need_server "$name"; fi

    local refresh=${MCCTL_REFRESH:-2}
    if [[ ! $refresh =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        die "MCCTL_REFRESH='$refresh' is not a number (use 0.2 to 3600)" "$EX_USAGE"
    fi
    if ! awk -v r="$refresh" 'BEGIN { exit !(r >= 0.2 && r <= 3600) }'; then
        die "MCCTL_REFRESH='$refresh' is out of range (use 0.2 to 3600)" "$EX_USAGE"
    fi

    if [[ ! -t 1 ]]; then
        NO_COLOR=1 _top_one_frame "$name"
        exit 0
    fi

    # The first frame is built before the alternate screen: if docker ps fails, the message stays on the normal screen (exit 1).
    local frame line
    frame=$(_top_one_frame "$name") || exit 1

    printf '\033[?1049h\033[?25l'
    _top_restore() { printf '\033[?25h\033[?1049l'; }
    trap '_top_restore; exit 0' INT
    trap '_top_restore' TERM EXIT

    while true; do
        printf '\033[H'
        while IFS= read -r line; do printf '%s\033[K\n' "$line"; done <<<"$frame"
        printf '\033[J'
        sleep "$refresh"
        # a later failure: restore the screen first, then print the message on the normal screen
        frame=$(_top_one_frame "$name" 2>&1) || { _top_restore; printf '%s\n' "$frame" >&2; exit 1; }
    done
}
