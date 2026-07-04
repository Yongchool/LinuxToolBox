#!/usr/bin/env bash
# collect_vmstat_perf.sh
#
# vmstat-oriented performance evidence collector.
#
# Purpose:
#   - Collect virtual memory / scheduler / CPU / swap / I/O wait evidence using vmstat.
#   - Preserve raw interval output, summarized averages, and before/after /proc snapshots.
#   - Support duration/interval based collection similar to other perf collectors.
#
# Default:
#   - 10 minutes total duration
#   - 60 seconds interval
#   - About 10 interval samples, plus vmstat's first since-boot line is kept in raw output
#     but excluded from summary averages.
#
# Supported targets:
#   Ubuntu 22.04/24.04, Debian 11/12, Oracle Linux, RHEL 8/9, SLES 12 SP5/15 SP6
#
# Optional tools used when available:
#   pidstat, iostat, sar, free, slabtop, numastat, journalctl, dmesg, top, ps
#
# Modes:
#   basic  : vmstat raw + summary + /proc/vmstat/meminfo before/after
#   detail : basic + ps/top/free/slab/zoneinfo/vmstat deltas + dmesg/journal tail
#   full   : detail + optional sysstat/pidstat/iostat/sar when available
#
# Examples:
#   ./collect_vmstat_perf.sh -o /var/tmp/vmstat_bundle
#   ./collect_vmstat_perf.sh -d 600 -i 60 -m detail -o /var/tmp/vmstat_detail
#   ./collect_vmstat_perf.sh -d 1800 -i 30 -m full --compress -o /var/tmp/vmstat_full
#

set -u
umask 077
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

DURATION=600
INTERVAL=60
MODE="basic"
OUTDIR=""
COMPRESS=0
SCRIPT_NAME=$(basename "$0")
START_EPOCH=""

usage() {
    cat <<'EOF'
Usage:
  collect_vmstat_perf.sh [options]

Options:
  -o DIR      Output directory. Default: ./vmstat_bundle_YYYYmmdd_HHMMSS
  -d SEC      Total collection duration in seconds. Default: 600
  -i SEC      vmstat interval in seconds. Default: 60
  -m MODE     Collection mode: basic, detail, full. Default: basic
  --compress  Create tar.gz archive at the end if tar/gzip are available.
  -h, --help  Show this help.

Modes:
  basic:
    - vmstat interval raw output
    - vmstat interval averages excluding first since-boot sample
    - /proc/vmstat and /proc/meminfo before/after
    - selected /proc/vmstat deltas

  detail:
    - basic
    - ps/top/free snapshots
    - slabinfo/zoneinfo/buddyinfo where readable
    - dmesg/journal tail for memory/swap/OOM/lockup clues

  full:
    - detail
    - pidstat/iostat/sar if available

Notes:
  Linux vmstat usually prints the first numeric line as an average since boot.
  This script keeps that line in raw output but excludes it from computed averages.
EOF
}

log() { printf '%s\n' "$*" >&2; }
error_exit() { log "ERROR: $*"; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
now_epoch() { date +%s; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

safe_read() {
    local path="$1"
    if [ -r "$path" ]; then
        cat "$path" 2>/dev/null || true
    else
        echo "UNREADABLE_OR_NOT_PRESENT"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o)
                [ "$#" -ge 2 ] || error_exit "-o requires directory"
                OUTDIR=$2; shift 2 ;;
            -d)
                [ "$#" -ge 2 ] || error_exit "-d requires seconds"
                DURATION=$2; shift 2 ;;
            -i)
                [ "$#" -ge 2 ] || error_exit "-i requires seconds"
                INTERVAL=$2; shift 2 ;;
            -m)
                [ "$#" -ge 2 ] || error_exit "-m requires mode"
                MODE=$2; shift 2 ;;
            --compress)
                COMPRESS=1; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                error_exit "unknown option: $1" ;;
        esac
    done
}

validate_args() {
    is_uint "$DURATION" || error_exit "duration must be integer"
    is_uint "$INTERVAL" || error_exit "interval must be integer"
    [ "$DURATION" -gt 0 ] || error_exit "duration must be > 0"
    [ "$INTERVAL" -gt 0 ] || error_exit "interval must be > 0"

    case "$MODE" in
        basic|detail|full) : ;;
        *) error_exit "invalid mode: $MODE" ;;
    esac

    have_cmd vmstat || error_exit "vmstat is required but not found. Install procps/procps-ng."

    if [ -z "$OUTDIR" ]; then
        OUTDIR="./vmstat_bundle_$(date +%Y%m%d_%H%M%S)"
    fi
}

preflight_dirs() {
    mkdir -p "$OUTDIR" "$OUTDIR/raw" "$OUTDIR/summary" "$OUTDIR/proc" "$OUTDIR/static" "$OUTDIR/logs" "$OUTDIR/optional" || \
        error_exit "failed to create output directory: $OUTDIR"
}

vmstat_args() {
    # Prefer wide output and timestamp if supported.
    local args=""
    if vmstat --help 2>&1 | grep -q -- ' -w'; then
        args="$args -w"
    fi
    if vmstat --help 2>&1 | grep -q -- ' -t'; then
        args="$args -t"
    fi
    printf '%s' "$args"
}

save_metadata() {
    local meta="$OUTDIR/00_metadata.txt"
    local args
    args=$(vmstat_args)
    {
        echo "script=$SCRIPT_NAME"
        echo "started_at_utc=$(now_utc)"
        echo "started_at_epoch=$(now_epoch)"
        echo "duration=$DURATION"
        echo "interval=$INTERVAL"
        echo "mode=$MODE"
        echo "outdir=$OUTDIR"
        echo "vmstat_args=$args $INTERVAL COUNT"
        echo
        echo "[hostname]"
        hostname 2>/dev/null || uname -n
        echo
        echo "[kernel]"
        uname -a
        echo
        echo "[os-release]"
        [ -r /etc/os-release ] && cat /etc/os-release || echo "not available"
        echo
        echo "[vmstat version/help]"
        vmstat -V 2>&1 || true
        echo
        echo "[available commands]"
        for c in vmstat free top ps dmesg journalctl pidstat iostat sar slabtop numastat tar gzip awk sed grep; do
            if have_cmd "$c"; then
                echo "$c=YES ($(command -v "$c"))"
            else
                echo "$c=NO"
            fi
        done
    } > "$meta"
}

capture_static_context() {
    {
        echo "[uptime]"
        uptime 2>/dev/null || true
        echo
        echo "[cpu online]"
        safe_read /sys/devices/system/cpu/online
        echo
        echo "[memory hotplug state]"
        safe_read /sys/devices/system/memory/block_size_bytes
        echo
        echo "[swaps]"
        safe_read /proc/swaps
        echo
        echo "[mounts]"
        safe_read /proc/mounts
        echo
        echo "[pressure stall information]"
        for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
            echo "--- $f ---"
            safe_read "$f"
        done
    } > "$OUTDIR/static/system_context.txt"
}

capture_before_after_proc() {
    local phase="$1"
    mkdir -p "$OUTDIR/proc/$phase"
    safe_read /proc/vmstat > "$OUTDIR/proc/$phase/proc_vmstat.txt"
    safe_read /proc/meminfo > "$OUTDIR/proc/$phase/proc_meminfo.txt"
    safe_read /proc/zoneinfo > "$OUTDIR/proc/$phase/proc_zoneinfo.txt"
    safe_read /proc/buddyinfo > "$OUTDIR/proc/$phase/proc_buddyinfo.txt"
    safe_read /proc/slabinfo > "$OUTDIR/proc/$phase/proc_slabinfo.txt"
    safe_read /proc/pressure/cpu > "$OUTDIR/proc/$phase/pressure_cpu.txt"
    safe_read /proc/pressure/memory > "$OUTDIR/proc/$phase/pressure_memory.txt"
    safe_read /proc/pressure/io > "$OUTDIR/proc/$phase/pressure_io.txt"
}

collect_detail_snapshot() {
    local phase="$1"
    local dir="$OUTDIR/summary/${phase}_runtime"
    mkdir -p "$dir"

    free -m > "$dir/free_m.txt" 2>&1 || true
    top -b -n 1 > "$dir/top.txt" 2>&1 || true
    ps -eo pid,ppid,stat,comm,%cpu,%mem,rss,vsz,wchan:32,etime,args --sort=-rss > "$dir/ps_by_rss.txt" 2>&1 || true
    ps -eo pid,ppid,stat,comm,%cpu,%mem,rss,vsz,wchan:32,etime,args --sort=-%cpu > "$dir/ps_by_cpu.txt" 2>&1 || true
    dmesg > "$dir/dmesg_tail_raw.txt" 2>&1 || true
    dmesg 2>/dev/null | grep -Ei 'oom|out of memory|memory allocation|page allocation|swap|soft lockup|hard lockup|hung task|blocked for more than' | tail -n 300 > "$dir/dmesg_memory_lockup_tail.txt" 2>&1 || true

    if have_cmd journalctl; then
        journalctl -k --no-pager -n 500 > "$dir/journal_kernel_tail.txt" 2>&1 || true
        journalctl -k --no-pager -n 1000 2>/dev/null | grep -Ei 'oom|out of memory|memory allocation|page allocation|swap|soft lockup|hard lockup|hung task|blocked for more than' > "$dir/journal_memory_lockup_tail.txt" 2>&1 || true
    fi

    if have_cmd slabtop; then
        slabtop -o > "$dir/slabtop_o.txt" 2>&1 || true
    fi

    if have_cmd numastat; then
        numastat > "$dir/numastat.txt" 2>&1 || true
        numastat -m > "$dir/numastat_m.txt" 2>&1 || true
    fi
}

run_optional_sysstat() {
    local count="$1"
    [ "$MODE" = "full" ] || return 0

    if have_cmd pidstat; then
        pidstat -urd -h -p ALL "$INTERVAL" "$count" > "$OUTDIR/optional/pidstat_urd.txt" 2>&1 &
        echo $! > "$OUTDIR/optional/pidstat.pid"
    fi

    if have_cmd iostat; then
        iostat -x -m "$INTERVAL" "$count" > "$OUTDIR/optional/iostat_xm.txt" 2>&1 &
        echo $! > "$OUTDIR/optional/iostat.pid"
    fi

    if have_cmd sar; then
        sar -r -B -W -q "$INTERVAL" "$count" > "$OUTDIR/optional/sar_memory_queue.txt" 2>&1 &
        echo $! > "$OUTDIR/optional/sar.pid"
    fi
}

wait_optional_sysstat() {
    for f in "$OUTDIR"/optional/*.pid; do
        [ -f "$f" ] || continue
        pid=$(cat "$f" 2>/dev/null || true)
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
}

write_avg_awk() {
    cat > "$OUTDIR/summary/vmstat_average.awk" <<'AWK'
BEGIN {
  saw_header = 0
  skipped_boot_line = 0
  rows = 0
}
/^[[:space:]]*r[[:space:]]+b[[:space:]]+/ {
  header = $0
  saw_header = 1
  next
}
{
  if (!saw_header) next
  if ($0 ~ /^[[:space:]]*$/) next
  if ($1 !~ /^-?[0-9]+$/) next

  # First numeric vmstat line is generally since-boot average; exclude from interval averages.
  if (!skipped_boot_line) {
    skipped_boot_line = 1
    next
  }

  rows++
  if (NF > max_nf) max_nf = NF
  for (i = 1; i <= NF; i++) {
    if ($i ~ /^-?[0-9]+([.][0-9]+)?$/) {
      sum[i] += $i
      numeric[i] = 1
    }
  }
}
END {
  print "VMSTAT interval averages"
  print "------------------------"
  if (header != "") print header
  if (rows == 0) {
    print "No interval rows parsed"
    exit
  }
  for (i = 1; i <= max_nf; i++) {
    if (i > 1) printf " "
    if (numeric[i]) {
      avg = sum[i] / rows
      if (avg == int(avg)) printf "%d", avg
      else printf "%.2f", avg
    } else {
      printf "-"
    }
  }
  printf "\n"
  print "rows=" rows
}
AWK
}

write_delta_awk() {
    cat > "$OUTDIR/summary/proc_vmstat_delta.awk" <<'AWK'
function load(path, arr,   k, v) {
  while ((getline < path) > 0) {
    if ($1 != "" && $2 ~ /^-?[0-9]+$/) {
      arr[$1] = $2
    }
  }
  close(path)
}
BEGIN {
  load(before, b)
  load(after, a)
  split("pgfault pgmajfault pgpgin pgpgout pswpin pswpout pgfree pgactivate pgdeactivate pgscan_kswapd pgscan_direct pgsteal_kswapd pgsteal_direct allocstall kswapd_inodesteal oom_kill compact_stall compact_fail compact_success nr_dirty nr_writeback", keys, " ")
  print "Selected /proc/vmstat deltas"
  print "------------------------------"
  for (i = 1; i <= length(keys); i++) {
    k = keys[i]
    if ((k in a) && (k in b)) {
      printf "%-24s %d\n", k, a[k] - b[k]
    }
  }
}
AWK
}

summarize_results() {
    write_avg_awk
    write_delta_awk

    awk -f "$OUTDIR/summary/vmstat_average.awk" "$OUTDIR/raw/vmstat_raw.txt" > "$OUTDIR/summary/vmstat_averages.txt" 2>&1 || true
    awk -v before="$OUTDIR/proc/before/proc_vmstat.txt" -v after="$OUTDIR/proc/after/proc_vmstat.txt" -f "$OUTDIR/summary/proc_vmstat_delta.awk" > "$OUTDIR/summary/proc_vmstat_deltas.txt" 2>&1 || true

    {
        echo "[vmstat averages]"
        cat "$OUTDIR/summary/vmstat_averages.txt" 2>/dev/null || true
        echo
        echo "[proc vmstat deltas]"
        cat "$OUTDIR/summary/proc_vmstat_deltas.txt" 2>/dev/null || true
        echo
        echo "[memory before]"
        grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback|Slab|SReclaimable|SUnreclaim):' "$OUTDIR/proc/before/proc_meminfo.txt" 2>/dev/null || true
        echo
        echo "[memory after]"
        grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback|Slab|SReclaimable|SUnreclaim):' "$OUTDIR/proc/after/proc_meminfo.txt" 2>/dev/null || true
    } > "$OUTDIR/summary/00_summary.txt"
}

compress_output() {
    [ "$COMPRESS" -eq 1 ] || return 0
    have_cmd tar || { log "WARN: tar not available; skip compression"; return 0; }
    have_cmd gzip || { log "WARN: gzip not available; skip compression"; return 0; }

    local parent base archive
    parent=$(dirname "$OUTDIR")
    base=$(basename "$OUTDIR")
    archive="${OUTDIR}.tar.gz"
    (cd "$parent" && tar -czf "$archive" "$base") 2>/dev/null || log "WARN: compression failed"
}

main() {
    parse_args "$@"
    validate_args
    preflight_dirs
    START_EPOCH=$(now_epoch)

    local count
    count=$((DURATION / INTERVAL + 1))
    [ "$count" -lt 2 ] && count=2

    local args
    args=$(vmstat_args)

    save_metadata
    capture_static_context
    capture_before_after_proc before
    [ "$MODE" = "detail" ] || [ "$MODE" = "full" ] && collect_detail_snapshot before

    log "INFO: output directory: $OUTDIR"
    log "INFO: mode=$MODE duration=$DURATION interval=$INTERVAL count=$count"
    log "INFO: running vmstat$args $INTERVAL $count"

    run_optional_sysstat "$count"
    # shellcheck disable=SC2086
    vmstat $args "$INTERVAL" "$count" > "$OUTDIR/raw/vmstat_raw.txt" 2>&1
    wait_optional_sysstat

    capture_before_after_proc after
    [ "$MODE" = "detail" ] || [ "$MODE" = "full" ] && collect_detail_snapshot after

    summarize_results

    {
        echo "completed_at_utc=$(now_utc)"
        echo "completed_at_epoch=$(now_epoch)"
        echo "vmstat_count=$count"
    } > "$OUTDIR/99_collection_end.txt"

    compress_output
    log "INFO: completed: $OUTDIR"
}

main "$@"
