#!/usr/bin/env bash
# collect_meminfo_perf.sh
#
# /proc/meminfo-oriented performance evidence collector.
#
# Purpose:
#   - Collect timestamped /proc/meminfo snapshots for memory pressure analysis.
#   - Preserve raw snapshots, normalized key/value tables, before/after delta summary,
#     and optional process/runtime context.
#   - Support duration/interval based collection similar to other perf collectors.
#
# Default:
#   - 10 minutes total duration
#   - 60 seconds interval
#   - About 10 snapshots
#
# Supported targets:
#   Ubuntu 22.04/24.04, Debian 11/12, Oracle Linux, RHEL 8/9, SLES 12 SP5/15 SP6
#
# Optional tools used when available:
#   free, vmstat, top, ps, slabtop, numastat, journalctl, dmesg, sar
#
# Modes:
#   basic  : /proc/meminfo snapshots + before/after delta + selected summary
#   detail : basic + vmstat/free/top/ps + slab/zone/buddy/pressure snapshots
#   full   : detail + sar/numastat/slabtop if available + logs each interval
#
# Examples:
#   ./collect_meminfo_perf.sh -o /var/tmp/meminfo_bundle
#   ./collect_meminfo_perf.sh -d 600 -i 60 -m detail -o /var/tmp/meminfo_detail
#   ./collect_meminfo_perf.sh -d 1800 -i 30 -m full --compress -o /var/tmp/meminfo_full
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
  collect_meminfo_perf.sh [options]

Options:
  -o DIR      Output directory. Default: ./meminfo_bundle_YYYYmmdd_HHMMSS
  -d SEC      Total collection duration in seconds. Default: 600
  -i SEC      Collection interval in seconds. Default: 60
  -m MODE     Collection mode: basic, detail, full. Default: basic
  --compress  Create tar.gz archive at the end if tar/gzip are available.
  -h, --help  Show this help.

Modes:
  basic:
    - /proc/meminfo raw snapshots every interval
    - selected memory fields summary per snapshot
    - before/after delta for numeric meminfo fields

  detail:
    - basic
    - free/vmstat/top/ps snapshots
    - /proc/vmstat, /proc/zoneinfo, /proc/buddyinfo, /proc/slabinfo, /proc/pressure/*

  full:
    - detail
    - slabtop/numastat/sar if available
    - memory/OOM/swap-related dmesg/journal excerpts each interval

Notes:
  /proc/meminfo values are usually reported in kB, except HugePages counters and
  some architecture/kernel-specific fields. This script keeps raw values and also
  derives MB for common kB fields in selected summaries.
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

    [ -r /proc/meminfo ] || error_exit "/proc/meminfo is not readable"

    if [ -z "$OUTDIR" ]; then
        OUTDIR="./meminfo_bundle_$(date +%Y%m%d_%H%M%S)"
    fi
}

preflight_dirs() {
    mkdir -p "$OUTDIR" "$OUTDIR/raw" "$OUTDIR/summary" "$OUTDIR/snapshots" "$OUTDIR/proc" "$OUTDIR/static" "$OUTDIR/logs" "$OUTDIR/optional" || \
        error_exit "failed to create output directory: $OUTDIR"
}

save_metadata() {
    local meta="$OUTDIR/00_metadata.txt"
    {
        echo "script=$SCRIPT_NAME"
        echo "started_at_utc=$(now_utc)"
        echo "started_at_epoch=$(now_epoch)"
        echo "duration=$DURATION"
        echo "interval=$INTERVAL"
        echo "mode=$MODE"
        echo "outdir=$OUTDIR"
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
        echo "[available commands]"
        for c in free vmstat top ps dmesg journalctl slabtop numastat sar tar gzip awk sed grep; do
            if have_cmd "$c"; then
                echo "$c=YES ($(command -v "$c"))"
            else
                echo "$c=NO"
            fi
        done
        echo
        echo "[important proc files]"
        for f in /proc/meminfo /proc/vmstat /proc/zoneinfo /proc/buddyinfo /proc/slabinfo /proc/swaps /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
            if [ -r "$f" ]; then
                echo "$f=READABLE"
            else
                echo "$f=UNREADABLE_OR_NOT_PRESENT"
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
        echo "[memory block size]"
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

snapshot_meminfo_selected() {
    local src="$1"
    local dst="$2"
    awk '
    BEGIN {
      split("MemTotal MemFree MemAvailable Buffers Cached SwapCached Active Inactive Active_anon Inactive_anon Active_file Inactive_file Unevictable Mlocked SwapTotal SwapFree Dirty Writeback AnonPages Mapped Shmem KReclaimable Slab SReclaimable SUnreclaim KernelStack PageTables SecPageTables NFS_Unstable Bounce WritebackTmp CommitLimit Committed_AS VmallocTotal VmallocUsed VmallocChunk Percpu HardwareCorrupted AnonHugePages ShmemHugePages ShmemPmdMapped FileHugePages FilePmdMapped HugePages_Total HugePages_Free HugePages_Rsvd HugePages_Surp Hugepagesize Hugetlb DirectMap4k DirectMap2M DirectMap1G", keys, " ")
      for (i in keys) want[keys[i]] = 1
      printf "%-28s %16s %12s %s\n", "field", "value", "MB", "unit"
      printf "%-28s %16s %12s %s\n", "----------------------------", "----------------", "------------", "----"
    }
    {
      key=$1
      gsub(":", "", key)
      if (key in want) {
        val=$2
        unit=$3
        mb="-"
        if (unit == "kB" && val ~ /^[0-9]+$/) {
          mb=sprintf("%.2f", val/1024)
        }
        printf "%-28s %16s %12s %s\n", key, val, mb, unit
      }
    }
    ' "$src" > "$dst" 2>&1 || true
}

collect_proc_snapshot() {
    local dir="$1"
    mkdir -p "$dir/proc" "$dir/summary" || return 0

    safe_read /proc/meminfo > "$dir/proc/meminfo.txt"
    snapshot_meminfo_selected "$dir/proc/meminfo.txt" "$dir/summary/meminfo_selected.txt"

    if [ "$MODE" = "detail" ] || [ "$MODE" = "full" ]; then
        safe_read /proc/vmstat > "$dir/proc/vmstat.txt"
        safe_read /proc/zoneinfo > "$dir/proc/zoneinfo.txt"
        safe_read /proc/buddyinfo > "$dir/proc/buddyinfo.txt"
        safe_read /proc/slabinfo > "$dir/proc/slabinfo.txt"
        safe_read /proc/swaps > "$dir/proc/swaps.txt"
        safe_read /proc/pressure/cpu > "$dir/proc/pressure_cpu.txt"
        safe_read /proc/pressure/memory > "$dir/proc/pressure_memory.txt"
        safe_read /proc/pressure/io > "$dir/proc/pressure_io.txt"
    fi
}

collect_runtime_snapshot() {
    local dir="$1"
    mkdir -p "$dir/runtime" || return 0

    if [ "$MODE" = "detail" ] || [ "$MODE" = "full" ]; then
        free -m > "$dir/runtime/free_m.txt" 2>&1 || true
        vmstat 1 2 > "$dir/runtime/vmstat_1_2.txt" 2>&1 || true
        top -b -n 1 > "$dir/runtime/top.txt" 2>&1 || true
        ps -eo pid,ppid,stat,comm,%cpu,%mem,rss,vsz,wchan:32,etime,args --sort=-rss > "$dir/runtime/ps_by_rss.txt" 2>&1 || true
        ps -eo pid,ppid,stat,comm,%cpu,%mem,rss,vsz,wchan:32,etime,args --sort=-%cpu > "$dir/runtime/ps_by_cpu.txt" 2>&1 || true
    fi

    if [ "$MODE" = "full" ]; then
        if have_cmd slabtop; then
            slabtop -o > "$dir/runtime/slabtop_o.txt" 2>&1 || true
        fi
        if have_cmd numastat; then
            numastat > "$dir/runtime/numastat.txt" 2>&1 || true
            numastat -m > "$dir/runtime/numastat_m.txt" 2>&1 || true
        fi
        if have_cmd sar; then
            sar -r -B -W -q 1 3 > "$dir/runtime/sar_memory_queue.txt" 2>&1 || true
        fi
    fi
}

collect_log_snapshot() {
    local dir="$1"
    mkdir -p "$dir/logs" || return 0

    if [ "$MODE" = "full" ]; then
        dmesg > "$dir/logs/dmesg_raw_tail.txt" 2>&1 || true
        dmesg 2>/dev/null | grep -Ei 'oom|out of memory|memory allocation|page allocation|swap|kswapd|direct reclaim|compaction|soft lockup|hard lockup|hung task|blocked for more than' | tail -n 500 > "$dir/logs/dmesg_memory_tail.txt" 2>&1 || true
        if have_cmd journalctl; then
            journalctl -k --no-pager -n 1000 > "$dir/logs/journal_kernel_tail.txt" 2>&1 || true
            journalctl -k --no-pager -n 2000 2>/dev/null | grep -Ei 'oom|out of memory|memory allocation|page allocation|swap|kswapd|direct reclaim|compaction|soft lockup|hard lockup|hung task|blocked for more than' > "$dir/logs/journal_memory_tail.txt" 2>&1 || true
        fi
    fi
}

collect_snapshot() {
    local sample_id="$1"
    local elapsed="$2"
    local dir="$OUTDIR/snapshots/sample_${sample_id}_elapsed_${elapsed}s"
    mkdir -p "$dir" || return 0

    {
        echo "sample_id=$sample_id"
        echo "elapsed=$elapsed"
        echo "timestamp_utc=$(now_utc)"
        echo "timestamp_epoch=$(now_epoch)"
        echo "mode=$MODE"
    } > "$dir/sample_meta.txt"

    collect_proc_snapshot "$dir"
    collect_runtime_snapshot "$dir"
    collect_log_snapshot "$dir"

    cp "$dir/proc/meminfo.txt" "$OUTDIR/raw/meminfo_sample_${sample_id}_elapsed_${elapsed}s.txt" 2>/dev/null || true
}

write_meminfo_delta_awk() {
    cat > "$OUTDIR/summary/meminfo_delta.awk" <<'AWK'
function load(path, arr, unitarr,   key, line, n, fields) {
  while ((getline line < path) > 0) {
    n = split(line, fields, /[[:space:]]+/)
    key = fields[1]
    gsub(":", "", key)
    if (n >= 2 && fields[2] ~ /^-?[0-9]+$/) {
      arr[key] = fields[2]
      unitarr[key] = fields[3]
    }
  }
  close(path)
}
BEGIN {
  load(before, b, bu)
  load(after, a, au)
  print "Meminfo before/after deltas"
  print "----------------------------"
  printf "%-28s %16s %16s %16s %s\n", "field", "before", "after", "delta", "unit"
  printf "%-28s %16s %16s %16s %s\n", "----------------------------", "----------------", "----------------", "----------------", "----"
  for (k in a) {
    if (k in b) {
      unit = au[k]
      if (unit == "") unit = bu[k]
      printf "%-28s %16d %16d %16d %s\n", k, b[k], a[k], a[k]-b[k], unit
    }
  }
}
AWK
}

write_meminfo_timeseries_awk() {
    cat > "$OUTDIR/summary/meminfo_timeseries.awk" <<'AWK'
BEGIN {
  split("MemTotal MemFree MemAvailable Buffers Cached SwapTotal SwapFree Dirty Writeback Slab SReclaimable SUnreclaim AnonPages Mapped Shmem CommitLimit Committed_AS", keys, " ")
  for (i=1;i<=length(keys);i++) want[keys[i]]=i
}
FNR==1 {
  sample++
  file=FILENAME
  elapsed="unknown"
  if (match(file, /elapsed_([0-9]+)s/, m)) elapsed=m[1]
  elapsed_by_sample[sample]=elapsed
}
{
  key=$1
  gsub(":", "", key)
  if (key in want && $2 ~ /^[0-9]+$/) {
    data[sample,key]=$2
  }
}
END {
  printf "sample elapsed"
  for (i=1;i<=length(keys);i++) printf " %s_kB", keys[i]
  printf "\n"
  for (s=1;s<=sample;s++) {
    printf "%d %s", s, elapsed_by_sample[s]
    for (i=1;i<=length(keys);i++) {
      k=keys[i]
      v=((s,k) in data)?data[s,k]:"NA"
      printf " %s", v
    }
    printf "\n"
  }
}
AWK
}

summarize_results() {
    write_meminfo_delta_awk
    write_meminfo_timeseries_awk

    first=$(ls "$OUTDIR"/raw/meminfo_sample_* 2>/dev/null | head -n 1 || true)
    last=$(ls "$OUTDIR"/raw/meminfo_sample_* 2>/dev/null | tail -n 1 || true)

    if [ -n "$first" ] && [ -n "$last" ]; then
        awk -v before="$first" -v after="$last" -f "$OUTDIR/summary/meminfo_delta.awk" > "$OUTDIR/summary/meminfo_deltas.txt" 2>&1 || true
    else
        echo "No meminfo samples found" > "$OUTDIR/summary/meminfo_deltas.txt"
    fi

    awk -f "$OUTDIR/summary/meminfo_timeseries.awk" "$OUTDIR"/raw/meminfo_sample_* > "$OUTDIR/summary/meminfo_timeseries.tsv" 2>&1 || true

    {
        echo "[meminfo delta]"
        cat "$OUTDIR/summary/meminfo_deltas.txt" 2>/dev/null || true
        echo
        echo "[first selected fields]"
        [ -n "$first" ] && snapshot_meminfo_selected "$first" /dev/stdout || true
        echo
        echo "[last selected fields]"
        [ -n "$last" ] && snapshot_meminfo_selected "$last" /dev/stdout || true
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
    end_epoch=$((START_EPOCH + DURATION))

    save_metadata
    capture_static_context

    log "INFO: output directory: $OUTDIR"
    log "INFO: mode=$MODE duration=$DURATION interval=$INTERVAL"

    sample_id=0
    while :; do
        now=$(now_epoch)
        [ "$now" -ge "$end_epoch" ] && break
        elapsed=$((now - START_EPOCH))
        sample_id=$((sample_id + 1))
        collect_snapshot "$sample_id" "$elapsed"
        sleep "$INTERVAL"
    done

    summarize_results

    {
        echo "completed_at_utc=$(now_utc)"
        echo "completed_at_epoch=$(now_epoch)"
        echo "samples_collected=$sample_id"
    } > "$OUTDIR/99_collection_end.txt"

    compress_output
    log "INFO: completed: $OUTDIR"
}

main "$@"
