#!/usr/bin/env bash
# collect_datastore_survival.sh
#
# Data-store / crash-survival readiness and evidence collector.
#
# Purpose:
#   - Verify where performance/hang/panic evidence can be stored.
#   - Distinguish data sources from data stores:
#       debugfs/tracefs : source, not persistence
#       tmpfs           : optional hot spool, not persistent
#       pstore          : reboot-surviving last logs
#       kdump           : crash vmcore integration
#       netconsole      : remote printk path, optional
#   - Periodically collect datastore-related status for a defined duration/interval.
#
# Supported targets:
#   Ubuntu 22.04/24.04, Debian 11/12, Oracle Linux, RHEL 8/9, SLES 12 SP5/15 SP6
#
# Default:
#   10 minutes, 60 second interval, 10 snapshots
#
# Safety:
#   This script is read-mostly. It does not enable/disable kdump, watchdog, sysrq,
#   pstore, netconsole, debugfs, or tracefs. It only records their current status.
#
# Examples:
#   sudo ./collect_datastore_survival.sh -o /var/tmp/datastore_bundle
#   sudo ./collect_datastore_survival.sh -d 600 -i 60 -o /var/tmp/datastore_bundle
#   sudo ./collect_datastore_survival.sh --spool-dir /dev/shm/perfpmr_spool --flush-every 120 -o /var/tmp/datastore_bundle
#

set -u
umask 077
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

DURATION=600
INTERVAL=60
OUTDIR=""
SPOOL_DIR=""
FLUSH_EVERY=120
COMPRESS=0
SCRIPT_NAME=$(basename "$0")
START_EPOCH=""

usage() {
    cat <<'EOF'
Usage:
  collect_datastore_survival.sh [options]

Options:
  -o DIR      Durable output directory. Default: ./datastore_bundle_YYYYmmdd_HHMMSS
  -d SEC      Total collection duration in seconds. Default: 600
  -i SEC      Snapshot interval in seconds. Default: 60
  --spool-dir DIR
              Optional hot spool directory, ideally on tmpfs such as /dev/shm/perfpmr_spool.
              This is not persistent. Snapshot files are periodically flushed to OUTDIR.
  --flush-every SEC
              Flush spool to durable output every SEC seconds. Default: 120
  --compress  Create tar.gz archive at the end if tar and gzip are available.
  -h, --help  Show help.

Collected status items:
  - /sys/kernel/kexec_crash_loaded
  - /proc/cmdline crashkernel parameter
  - /sys/fs/pstore presence and content metadata
  - /proc/sys/kernel/watchdog
  - /proc/sys/kernel/softlockup_panic
  - /proc/sys/kernel/hardlockup_panic
  - /proc/sys/kernel/sysrq
  - debugfs / tracefs mount status
  - tmpfs / ramfs mount status
  - kdump service/package metadata where available
  - netconsole module status
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

safe_cp_file() {
    local src="$1"
    local dst="$2"
    if [ -r "$src" ]; then
        cp -p "$src" "$dst" 2>/dev/null || cat "$src" > "$dst" 2>/dev/null || true
    else
        echo "UNREADABLE_OR_NOT_PRESENT: $src" > "$dst"
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
            --spool-dir)
                [ "$#" -ge 2 ] || error_exit "--spool-dir requires directory"
                SPOOL_DIR=$2; shift 2 ;;
            --flush-every)
                [ "$#" -ge 2 ] || error_exit "--flush-every requires seconds"
                FLUSH_EVERY=$2; shift 2 ;;
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
    is_uint "$FLUSH_EVERY" || error_exit "flush interval must be integer"
    [ "$DURATION" -gt 0 ] || error_exit "duration must be > 0"
    [ "$INTERVAL" -gt 0 ] || error_exit "interval must be > 0"
    [ "$FLUSH_EVERY" -gt 0 ] || error_exit "flush interval must be > 0"

    if [ -z "$OUTDIR" ]; then
        OUTDIR="./datastore_bundle_$(date +%Y%m%d_%H%M%S)"
    fi
}

preflight_dirs() {
    mkdir -p "$OUTDIR" "$OUTDIR/snapshots" "$OUTDIR/static" "$OUTDIR/pstore" "$OUTDIR/kdump" "$OUTDIR/mounts" || \
        error_exit "failed to create output directory: $OUTDIR"

    if [ -n "$SPOOL_DIR" ]; then
        mkdir -p "$SPOOL_DIR" || error_exit "failed to create spool directory: $SPOOL_DIR"
        mkdir -p "$OUTDIR/spool_flushes" || error_exit "failed to create spool flush directory"
    fi
}

mount_type_of() {
    local path="$1"
    if have_cmd findmnt; then
        findmnt -no FSTYPE --target "$path" 2>/dev/null || true
    else
        awk -v p="$path" '$2 == p {print $3}' /proc/mounts 2>/dev/null | tail -n 1
    fi
}

save_metadata() {
    local meta="$OUTDIR/00_metadata.txt"
    {
        echo "script=$SCRIPT_NAME"
        echo "started_at_utc=$(now_utc)"
        echo "started_at_epoch=$(now_epoch)"
        echo "duration=$DURATION"
        echo "interval=$INTERVAL"
        echo "outdir=$OUTDIR"
        echo "spool_dir=${SPOOL_DIR:-none}"
        echo "flush_every=$FLUSH_EVERY"
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
        for c in systemctl journalctl kdumpctl makedumpfile crash findmnt mount df tar gzip lsmod modinfo dmesg; do
            if have_cmd "$c"; then
                echo "$c=YES ($(command -v "$c"))"
            else
                echo "$c=NO"
            fi
        done
        echo
        echo "[data-store policy]"
        echo "primary_store=regular filesystem timestamped output"
        echo "optional_hot_spool=tmpfs only, periodic flush recommended"
        echo "debugfs_role=data source only, not persistent storage"
        echo "tracefs_role=tracing source/control, not persistent storage"
        echo "pstore_role=reboot-surviving last logs, collect if present"
        echo "kdump_role=crash vmcore, verify/integrate"
        echo "netconsole_role=remote printk, optional"
    } > "$meta"
}

collect_static_mount_context() {
    {
        echo "[mount]"
        mount 2>/dev/null || true
        echo
        echo "[/proc/mounts]"
        cat /proc/mounts 2>/dev/null || true
        echo
        echo "[findmnt]"
        findmnt 2>/dev/null || true
        echo
        echo "[df -hT]"
        df -hT 2>/dev/null || true
        echo
        echo "[df -i]"
        df -i 2>/dev/null || true
    } > "$OUTDIR/mounts/mount_context.txt"

    {
        echo "debugfs_mount=$(mount_type_of /sys/kernel/debug)"
        echo "tracefs_mount=$(mount_type_of /sys/kernel/tracing)"
        echo "pstore_mount=$(mount_type_of /sys/fs/pstore)"
        [ -n "$SPOOL_DIR" ] && echo "spool_mount=$(mount_type_of "$SPOOL_DIR")"
    } > "$OUTDIR/mounts/important_mount_types.txt"
}

collect_static_kdump_context() {
    {
        echo "[/sys/kernel/kexec_crash_loaded]"
        safe_read /sys/kernel/kexec_crash_loaded
        echo
        echo "[/proc/cmdline]"
        safe_read /proc/cmdline
        echo
        echo "[crashkernel parameter]"
        if grep -qw 'crashkernel' /proc/cmdline 2>/dev/null; then
            tr ' ' '\n' < /proc/cmdline | grep '^crashkernel' || true
        else
            echo "crashkernel parameter not found"
        fi
        echo
        echo "[kdumpctl status]"
        if have_cmd kdumpctl; then
            kdumpctl status 2>&1 || true
        else
            echo "kdumpctl not available"
        fi
        echo
        echo "[systemctl kdump status]"
        if have_cmd systemctl; then
            systemctl status kdump 2>&1 || true
        else
            echo "systemctl not available"
        fi
        echo
        echo "[kdump config files]"
        for f in /etc/kdump.conf /etc/default/kdump-tools /etc/sysconfig/kdump; do
            echo "--- $f ---"
            [ -r "$f" ] && sed -n '1,240p' "$f" || echo "not present or unreadable"
        done
    } > "$OUTDIR/kdump/kdump_context.txt"
}

collect_static_pstore_context() {
    local pdir="$OUTDIR/pstore"
    {
        echo "[pstore directory]"
        if [ -d /sys/fs/pstore ]; then
            ls -la /sys/fs/pstore 2>&1 || true
        else
            echo "/sys/fs/pstore not present"
        fi
        echo
        echo "[pstore mount]"
        grep '[[:space:]]/sys/fs/pstore[[:space:]]' /proc/mounts 2>/dev/null || echo "pstore not mounted according to /proc/mounts"
        echo
        echo "[pstore backend clues]"
        dmesg 2>/dev/null | grep -Ei 'pstore|ramoops|efi.*pstore' | tail -n 100 || true
    } > "$pdir/pstore_context.txt"

    if [ -d /sys/fs/pstore ] && \
       find /sys/fs/pstore -mindepth 1 -type f -print -quit 2>/dev/null | grep -q .
    then
        mkdir -p "$pdir/files"
        for f in /sys/fs/pstore/*; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            safe_cp_file "$f" "$pdir/files/$base"
        done
    fi
}

collect_static_debug_trace_context() {
    local out="$OUTDIR/static/debug_trace_context.txt"
    {
        echo "[debugfs]"
        echo "path=/sys/kernel/debug"
        if [ -d /sys/kernel/debug ]; then
            ls -ld /sys/kernel/debug 2>&1 || true
            grep '[[:space:]]/sys/kernel/debug[[:space:]]' /proc/mounts 2>/dev/null || echo "debugfs not mounted"
        else
            echo "debugfs path not present"
        fi
        echo
        echo "[tracefs]"
        echo "path=/sys/kernel/tracing"
        if [ -d /sys/kernel/tracing ]; then
            ls -ld /sys/kernel/tracing 2>&1 || true
            grep '[[:space:]]/sys/kernel/tracing[[:space:]]' /proc/mounts 2>/dev/null || echo "tracefs not mounted at /sys/kernel/tracing"
        else
            echo "tracefs path not present at /sys/kernel/tracing"
        fi
        echo
        echo "[legacy tracing path]"
        if [ -d /sys/kernel/debug/tracing ]; then
            ls -ld /sys/kernel/debug/tracing 2>&1 || true
        else
            echo "/sys/kernel/debug/tracing not present"
        fi
    } > "$out"
}

collect_static_netconsole_context() {
    local out="$OUTDIR/static/netconsole_context.txt"
    {
        echo "[netconsole module]"
        if have_cmd lsmod; then
            lsmod | grep -E '^netconsole\b' || echo "netconsole module not loaded"
        else
            grep -w '^netconsole' /proc/modules 2>/dev/null || echo "netconsole module not loaded or /proc/modules unavailable"
        fi
        echo
        echo "[modinfo netconsole]"
        if have_cmd modinfo; then
            modinfo netconsole 2>&1 || true
        else
            echo "modinfo not available"
        fi
        echo
        echo "[netconsole configfs clues]"
        if [ -d /sys/kernel/config/netconsole ]; then
            find /sys/kernel/config/netconsole -maxdepth 3 -type f -print 2>/dev/null | while read -r f; do
                echo "--- $f ---"
                cat "$f" 2>/dev/null || true
            done
        else
            echo "/sys/kernel/config/netconsole not present"
        fi
    } > "$out"
}

collect_snapshot() {
    local sample_id="$1"
    local elapsed="$2"
    local base="$3"
    local dir="$base/snapshot_${sample_id}_elapsed_${elapsed}s"
    mkdir -p "$dir" || return 0

    {
        echo "sample_id=$sample_id"
        echo "elapsed=$elapsed"
        echo "timestamp_utc=$(now_utc)"
        echo "timestamp_epoch=$(now_epoch)"
    } > "$dir/sample_meta.txt"

    {
        echo "[kdump loaded] /sys/kernel/kexec_crash_loaded"
        safe_read /sys/kernel/kexec_crash_loaded
        echo
        echo "[crashkernel cmdline]"
        tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep '^crashkernel' || echo "crashkernel parameter not found"
        echo
        echo "[pstore mounted/path]"
        if [ -d /sys/fs/pstore ]; then
            echo "pstore_path=present"
            grep '[[:space:]]/sys/fs/pstore[[:space:]]' /proc/mounts 2>/dev/null || echo "pstore_mount=not found in /proc/mounts"
            ls -la /sys/fs/pstore 2>&1 || true
        else
            echo "pstore_path=not_present"
        fi
        echo
        echo "[lockup watchdog] /proc/sys/kernel/watchdog"
        safe_read /proc/sys/kernel/watchdog
        echo
        echo "[softlockup panic] /proc/sys/kernel/softlockup_panic"
        safe_read /proc/sys/kernel/softlockup_panic
        echo
        echo "[hardlockup panic] /proc/sys/kernel/hardlockup_panic"
        safe_read /proc/sys/kernel/hardlockup_panic
        echo
        echo "[sysrq enabled] /proc/sys/kernel/sysrq"
        safe_read /proc/sys/kernel/sysrq
    } > "$dir/datastore_status.txt"

    {
        echo "[printk]"
        safe_read /proc/sys/kernel/printk
        echo
        echo "[dmesg tail]"
        dmesg 2>/dev/null | tail -n 200 || true
        echo
        echo "[journal recent kernel logs]"
        if have_cmd journalctl; then
            journalctl -k --no-pager -n 200 2>/dev/null || true
        else
            echo "journalctl not available"
        fi
    } > "$dir/kernel_log_tail.txt"

    {
        echo "[vmstat]"
        vmstat 1 2 2>&1 || true
        echo
        echo "[top]"
        top -b -n 1 2>&1 || true
        echo
        echo "[ps blocked/uninterruptible candidates]"
        ps -eo pid,ppid,stat,comm,wchan:32,etime,args 2>/dev/null | awk 'NR==1 || $3 ~ /D/ {print}' || true
    } > "$dir/runtime_context.txt"
}

flush_spool_if_needed() {
    local elapsed="$1"
    [ -n "$SPOOL_DIR" ] || return 0
    [ $((elapsed % FLUSH_EVERY)) -eq 0 ] || return 0

    local flush_dir="$OUTDIR/spool_flushes/flush_elapsed_${elapsed}s"
    mkdir -p "$flush_dir" || return 0

    # Portable copy; rsync is not assumed.
    if [ -d "$SPOOL_DIR" ]; then
        cp -a "$SPOOL_DIR"/. "$flush_dir"/ 2>/dev/null || true
    fi
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
    local end_epoch=$((START_EPOCH + DURATION))

    save_metadata
    collect_static_mount_context
    collect_static_kdump_context
    collect_static_pstore_context
    collect_static_debug_trace_context
    collect_static_netconsole_context

    log "INFO: output directory: $OUTDIR"
    [ -n "$SPOOL_DIR" ] && log "INFO: optional spool directory: $SPOOL_DIR"
    log "INFO: duration=$DURATION interval=$INTERVAL"

    local sample_id=0
    local now elapsed target_base

    while :; do
        now=$(now_epoch)
        [ "$now" -ge "$end_epoch" ] && break
        elapsed=$((now - START_EPOCH))
        sample_id=$((sample_id + 1))

        if [ -n "$SPOOL_DIR" ]; then
            mkdir -p "$SPOOL_DIR/snapshots" 2>/dev/null || true
            target_base="$SPOOL_DIR/snapshots"
        else
            target_base="$OUTDIR/snapshots"
        fi

        collect_snapshot "$sample_id" "$elapsed" "$target_base"
        flush_spool_if_needed "$elapsed"
        sleep "$INTERVAL"
    done

    # Final flush from optional hot spool.
    if [ -n "$SPOOL_DIR" ] && [ -d "$SPOOL_DIR/snapshots" ]; then
        mkdir -p "$OUTDIR/snapshots" 2>/dev/null || true
        cp -a "$SPOOL_DIR/snapshots"/. "$OUTDIR/snapshots"/ 2>/dev/null || true
    fi

    {
        echo "completed_at_utc=$(now_utc)"
        echo "completed_at_epoch=$(now_epoch)"
        echo "samples_collected=$sample_id"
    } > "$OUTDIR/99_collection_end.txt"

    compress_output
    log "INFO: completed: $OUTDIR"
}

main "$@"
