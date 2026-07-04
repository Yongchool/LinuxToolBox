#!/usr/bin/env bash
# collect_sysrq_netconsole_perf.sh
#
# Safe SysRq + dmesg/netconsole-oriented performance evidence collector.
#
# Purpose:
#   - Periodically trigger non-destructive SysRq diagnostics and capture dmesg output.
#   - Help collect evidence for CPU soft lockup, scheduler hang, blocked task,
#     memory pressure, lock-related symptoms, and logging/netconsole readiness.
#   - Default collection is 10 minutes, 60 second interval, 10 snapshots.
#
# Supported targets:
#   Ubuntu 22.04/24.04, Debian 11/12, Oracle Linux, RHEL 8/9, SLES 12 SP5/15 SP6
#
# Safety policy:
#   This script intentionally DOES NOT trigger destructive SysRq keys:
#     c = crash/panic
#     b = immediate reboot
#     f = OOM killer
#     s = sync
#     u = remount read-only
#   Only non-destructive diagnostic keys are used by predefined modes.
#
# Modes:
#   basic                 : m/w/p every interval, l by vCPU policy
#   detail                : m/w/p every interval, l by vCPU policy, t/d at start and end only
#   detail-aggressive     : m/w/p every interval, l by vCPU policy, t/d every 300s
#   full-every-interval   : m/w/l/p/t/d every interval
#
# Usage examples:
#   sudo ./collect_sysrq_netconsole_perf.sh -o /var/tmp/sysrq_bundle
#   sudo ./collect_sysrq_netconsole_perf.sh -m detail -d 600 -i 60 -o /var/tmp/sysrq_detail
#   sudo ./collect_sysrq_netconsole_perf.sh -m detail-aggressive -d 1200 -i 60 -o /var/tmp/sysrq_aggr
#   sudo ./collect_sysrq_netconsole_perf.sh --dry-run -m detail
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
RAISE_LOGLEVEL=1
SYSRQ_LOGLEVEL=8
DRY_RUN=0
KEEP_DEBUG=0
NETCONSOLE_REMOTE=""
NETCONSOLE_IFACE=""

SCRIPT_NAME=$(basename "$0")
START_EPOCH=""
ORIG_PRINTK=""

usage() {
    cat <<'EOF'
Usage:
  collect_sysrq_netconsole_perf.sh [options]

Options:
  -o DIR      Output directory. Default: ./sysrq_netconsole_bundle_YYYYmmdd_HHMMSS
  -d SEC      Total duration in seconds. Default: 600
  -i SEC      Snapshot interval in seconds. Default: 60
  -m MODE     Collection mode. One of:
                basic
                detail
                detail-aggressive
                full-every-interval
  --no-raise-loglevel
              Do not raise console loglevel with SysRq loglevel key.
  --sysrq-loglevel N
              SysRq console loglevel key to send before collection. Default: 8
  --netconsole-remote IP:PORT
              Record intended netconsole receiver metadata only. This script does not
              configure netconsole automatically.
  --netconsole-iface IFACE
              Record intended netconsole interface metadata only.
  --dry-run   Print planned actions without writing to /proc/sysrq-trigger.
  -h, --help  Show help.

Predefined safe SysRq keys used:
  m : memory usage
  w : blocked tasks
  l : backtrace for active CPUs
  p : registers/current CPU state
  t : all task states
  d : held locks, if supported by kernel

Destructive SysRq keys are blocked by design and are never sent by this script:
  c, b, f, s, u
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

get_vcpu_count() {
    if have_cmd nproc; then
        nproc 2>/dev/null && return 0
    fi
    if have_cmd getconf; then
        getconf _NPROCESSORS_ONLN 2>/dev/null && return 0
    fi
    grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
}

vreadonly() {
    [ -r "$1" ] && cat "$1" 2>/dev/null || true
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
            --no-raise-loglevel)
                RAISE_LOGLEVEL=0; shift ;;
            --sysrq-loglevel)
                [ "$#" -ge 2 ] || error_exit "--sysrq-loglevel requires value"
                SYSRQ_LOGLEVEL=$2; shift 2 ;;
            --netconsole-remote)
                [ "$#" -ge 2 ] || error_exit "--netconsole-remote requires IP:PORT"
                NETCONSOLE_REMOTE=$2; shift 2 ;;
            --netconsole-iface)
                [ "$#" -ge 2 ] || error_exit "--netconsole-iface requires IFACE"
                NETCONSOLE_IFACE=$2; shift 2 ;;
            --dry-run)
                DRY_RUN=1; shift ;;
            --keep-debug)
                KEEP_DEBUG=1; shift ;;
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
    is_uint "$SYSRQ_LOGLEVEL" || error_exit "sysrq loglevel must be integer 0-9"
    [ "$DURATION" -gt 0 ] || error_exit "duration must be > 0"
    [ "$INTERVAL" -gt 0 ] || error_exit "interval must be > 0"
    [ "$SYSRQ_LOGLEVEL" -ge 0 ] && [ "$SYSRQ_LOGLEVEL" -le 9 ] || error_exit "sysrq loglevel must be 0-9"

    case "$MODE" in
        basic|detail|detail-aggressive|full-every-interval) : ;;
        *) error_exit "invalid mode: $MODE" ;;
    esac

    if [ -z "$OUTDIR" ]; then
        OUTDIR="./sysrq_netconsole_bundle_$(date +%Y%m%d_%H%M%S)"
    fi
}

preflight() {
    mkdir -p "$OUTDIR" "$OUTDIR/snapshots" "$OUTDIR/dmesg" "$OUTDIR/proc" || error_exit "failed to create output directory: $OUTDIR"

    [ -w /proc/sysrq-trigger ] || log "WARN: /proc/sysrq-trigger is not writable. Run as root or use --dry-run."
    [ -r /proc/sys/kernel/sysrq ] || log "WARN: /proc/sys/kernel/sysrq is not readable."

    # dmesg may be restricted by kernel.dmesg_restrict.
    if ! dmesg >/dev/null 2>&1; then
        log "WARN: dmesg is not readable. Check root privileges or kernel.dmesg_restrict."
    fi
}

save_metadata() {
    local meta="$OUTDIR/00_metadata.txt"
    local vcpu
    vcpu=$(get_vcpu_count)

    {
        echo "script=$SCRIPT_NAME"
        echo "started_at_utc=$(now_utc)"
        echo "started_at_epoch=$(now_epoch)"
        echo "duration=$DURATION"
        echo "interval=$INTERVAL"
        echo "mode=$MODE"
        echo "dry_run=$DRY_RUN"
        echo "raise_loglevel=$RAISE_LOGLEVEL"
        echo "sysrq_loglevel=$SYSRQ_LOGLEVEL"
        echo "vcpu_count=$vcpu"
        echo "netconsole_remote=${NETCONSOLE_REMOTE:-none}"
        echo "netconsole_iface=${NETCONSOLE_IFACE:-none}"
        echo
        echo "[hostname]"
        hostname 2>/dev/null || uname -n
        echo
        echo "[uname]"
        uname -a
        echo
        echo "[os-release]"
        [ -r /etc/os-release ] && cat /etc/os-release || echo "not available"
        echo
        echo "[sysrq]"
        echo -n "/proc/sys/kernel/sysrq="
        vreadonly /proc/sys/kernel/sysrq
        echo -n "/proc/sys/kernel/printk="
        vreadonly /proc/sys/kernel/printk
        echo
        echo "[netconsole/module status]"
        if have_cmd lsmod; then
            lsmod | grep -E '^netconsole\b' || echo "netconsole module not loaded"
        else
            grep -w '^netconsole' /proc/modules 2>/dev/null || echo "netconsole module not loaded or /proc/modules unavailable"
        fi
        echo
        echo "[netconsole notes]"
        echo "This script does not configure netconsole automatically."
        echo "If disk logging is unreliable, configure netconsole separately before running this collector."
        echo "Example concept: modprobe netconsole netconsole=@LOCAL_IP/IFACE,@REMOTE_IP/REMOTE_MAC"
        echo "Receiver example: nc -klu 6666"
        echo
        echo "[available commands]"
        for c in dmesg journalctl ps top vmstat cat grep awk sed timeout nsenter; do
            if have_cmd "$c"; then
                echo "$c=YES ($(command -v "$c"))"
            else
                echo "$c=NO"
            fi
        done
    } > "$meta"
}

capture_baseline() {
    dmesg -T > "$OUTDIR/dmesg/dmesg_start_T.txt" 2>&1 || true
    dmesg > "$OUTDIR/dmesg/dmesg_start_raw.txt" 2>&1 || true
    cp /proc/sys/kernel/sysrq "$OUTDIR/proc/sysrq_start.txt" 2>/dev/null || true
    cp /proc/sys/kernel/printk "$OUTDIR/proc/printk_start.txt" 2>/dev/null || true
    ps -eo pid,ppid,stat,comm,wchan:32,etime,args --sort=pid > "$OUTDIR/proc/ps_start.txt" 2>&1 || true
    vmstat 1 2 > "$OUTDIR/proc/vmstat_start.txt" 2>&1 || true
    top -b -n 1 > "$OUTDIR/proc/top_start.txt" 2>&1 || true
}

raise_console_loglevel() {
    [ "$RAISE_LOGLEVEL" -eq 1 ] || return 0
    ORIG_PRINTK=$(cat /proc/sys/kernel/printk 2>/dev/null || true)

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRYRUN: would send SysRq loglevel key: $SYSRQ_LOGLEVEL"
        return 0
    fi

    if [ -w /proc/sysrq-trigger ]; then
        printf '%s\n' "$SYSRQ_LOGLEVEL" > /proc/sysrq-trigger || true
    else
        log "WARN: cannot write /proc/sysrq-trigger to raise loglevel"
    fi
}

restore_printk_loglevel() {
    # Avoid forcing restore by default with sysctl because console_loglevel may be intentionally changed by operator.
    # Original value is saved in metadata/proc files for reference.
    :
}

safe_sysrq_write() {
    local key="$1"

    case "$key" in
        c|b|f|s|u)
            log "BLOCKED: destructive SysRq key not sent: $key"
            return 0 ;;
    esac

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRYRUN: would send SysRq key: $key"
        return 0
    fi

    if [ ! -w /proc/sysrq-trigger ]; then
        log "WARN: /proc/sysrq-trigger is not writable; skipped key=$key"
        return 0
    fi

    printf '%s\n' "$key" > /proc/sysrq-trigger || log "WARN: failed to send SysRq key=$key"
}

send_sysrq_sequence() {
    local seq="$1"
    local i key
    i=1
    while [ "$i" -le "${#seq}" ]; do
        key=$(printf '%s' "$seq" | cut -c "$i")
        safe_sysrq_write "$key"
        # Small delay so printk lines are less likely to interleave too aggressively.
        sleep 1
        i=$((i + 1))
    done
}

policy_l_due() {
    local elapsed="$1"
    local vcpu="$2"
    local l_every

    # vCPU adaptive l interval policy.
    if [ "$vcpu" -le 64 ]; then
        l_every=60
    elif [ "$vcpu" -le 128 ]; then
        l_every=120
    elif [ "$vcpu" -le 511 ]; then
        l_every=300
    else
        # 512+ vCPU: l disabled by default in basic/detail/detail-aggressive.
        return 1
    fi

    [ $((elapsed % l_every)) -eq 0 ]
}

should_send_td() {
    local elapsed="$1"
    local is_start="$2"
    local is_end="$3"

    case "$MODE" in
        basic)
            return 1 ;;
        detail)
            [ "$is_start" -eq 1 ] || [ "$is_end" -eq 1 ] ;;
        detail-aggressive)
            [ "$is_start" -eq 1 ] || [ "$is_end" -eq 1 ] || [ $((elapsed % 300)) -eq 0 ] ;;
        full-every-interval)
            return 0 ;;
    esac
}

sample_once() {
    local sample_id="$1"
    local elapsed="$2"
    local is_start="$3"
    local is_end="$4"
    local vcpu="$5"
    local dir="$OUTDIR/snapshots/sample_${sample_id}_elapsed_${elapsed}s"
    local seq="mwp"

    mkdir -p "$dir" || return 0

    {
        echo "sample_id=$sample_id"
        echo "elapsed=$elapsed"
        echo "timestamp_utc=$(now_utc)"
        echo "mode=$MODE"
        echo "is_start=$is_start"
        echo "is_end=$is_end"
    } > "$dir/sample_meta.txt"

    # Basic recurring keys: memory, blocked tasks, registers/current CPU.
    # l is adaptive by vCPU count to reduce output amplification on large VMs.
    if [ "$MODE" = "full-every-interval" ] || policy_l_due "$elapsed" "$vcpu"; then
        seq="mwlp"
    fi

    if should_send_td "$elapsed" "$is_start" "$is_end"; then
        seq="${seq}td"
    fi

    echo "sysrq_sequence=$seq" >> "$dir/sample_meta.txt"
    send_sysrq_sequence "$seq"

    # Give printk/dmesg a small window to flush.
    sleep 2

    dmesg -T > "$dir/dmesg_T_after_sysrq.txt" 2>&1 || true
    dmesg > "$dir/dmesg_raw_after_sysrq.txt" 2>&1 || true
    ps -eo pid,ppid,stat,comm,wchan:32,etime,args --sort=pid > "$dir/ps.txt" 2>&1 || true
    vmstat 1 2 > "$dir/vmstat.txt" 2>&1 || true
    top -b -n 1 > "$dir/top.txt" 2>&1 || true
}

main() {
    parse_args "$@"
    validate_args
    preflight

    START_EPOCH=$(now_epoch)
    local end_epoch=$((START_EPOCH + DURATION))
    local vcpu
    vcpu=$(get_vcpu_count)

    save_metadata
    capture_baseline
    raise_console_loglevel

    log "INFO: output directory: $OUTDIR"
    log "INFO: mode=$MODE duration=$DURATION interval=$INTERVAL vcpu=$vcpu"

    local sample_id=0
    local now elapsed is_start is_end

    while :; do
        now=$(now_epoch)
        [ "$now" -ge "$end_epoch" ] && break

        elapsed=$((now - START_EPOCH))
        sample_id=$((sample_id + 1))
        is_start=0
        is_end=0
        [ "$sample_id" -eq 1 ] && is_start=1

        # If the next sleep would pass end time, mark this as near-end sample.
        [ $((now + INTERVAL)) -ge "$end_epoch" ] && is_end=1

        sample_once "$sample_id" "$elapsed" "$is_start" "$is_end" "$vcpu"
        sleep "$INTERVAL"
    done

    # Ensure detail mode gets a final t/d sample even if timing did not mark end in loop.
    if [ "$MODE" = "detail" ] || [ "$MODE" = "detail-aggressive" ]; then
        sample_id=$((sample_id + 1))
        elapsed=$(( $(now_epoch) - START_EPOCH ))
        sample_once "$sample_id" "$elapsed" 0 1 "$vcpu"
    fi

    dmesg -T > "$OUTDIR/dmesg/dmesg_end_T.txt" 2>&1 || true
    dmesg > "$OUTDIR/dmesg/dmesg_end_raw.txt" 2>&1 || true
    cp /proc/sys/kernel/printk "$OUTDIR/proc/printk_end.txt" 2>/dev/null || true
    cp /proc/sys/kernel/sysrq "$OUTDIR/proc/sysrq_end.txt" 2>/dev/null || true

    {
        echo "completed_at_utc=$(now_utc)"
        echo "completed_at_epoch=$(now_epoch)"
        echo "samples_collected=$sample_id"
        echo "original_printk=$ORIG_PRINTK"
    } > "$OUTDIR/99_collection_end.txt"

    restore_printk_loglevel
    log "INFO: completed: $OUTDIR"
}

main "$@"
