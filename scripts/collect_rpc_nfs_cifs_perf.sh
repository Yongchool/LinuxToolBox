#!/usr/bin/env bash
# collect_rpc_nfs_cifs_perf.sh
#
# RPC / NFS / CIFS performance and debug evidence collector.
#
# Purpose:
#   - Collect timestamped evidence for RPC/NFS/CIFS latency, hang, reconnect,
#     stale mount, server reachability, and client-side performance symptoms.
#   - Prefer read-only collection. This script does not enable kernel debug flags
#     or modify rpcdebug/dynamic_debug settings by default.
#   - Support duration/interval based snapshots, similar to other perf collectors.
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
#   nfsstat, nfsiostat, mountstats, rpcinfo, showmount, smbstatus, ss, netstat,
#   lsof, fuser, journalctl, findmnt, timeout, nsenter
#
# Modes:
#   basic  : lightweight recurring snapshots
#   detail : basic + journal/dmesg tail + lsof/fuser + richer per-mount evidence
#   full   : detail + raw proc/sys/module copies each interval
#
# Examples:
#   sudo ./collect_rpc_nfs_cifs_perf.sh -o /var/tmp/rpc_nfs_cifs_bundle
#   sudo ./collect_rpc_nfs_cifs_perf.sh -d 600 -i 60 -m detail -o /var/tmp/rpc_detail
#   sudo ./collect_rpc_nfs_cifs_perf.sh -d 1800 -i 120 -m full -o /var/tmp/rpc_full
#   sudo ./collect_rpc_nfs_cifs_perf.sh -n 1234 -m detail -o /var/tmp/ns_rpc_bundle
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
NETNS_PID=""
PORTS="111,2049,445,139"
COMPRESS=0
SCRIPT_NAME=$(basename "$0")
START_EPOCH=""

usage() {
    cat <<'EOF'
Usage:
  collect_rpc_nfs_cifs_perf.sh [options]

Options:
  -o DIR      Output directory. Default: ./rpc_nfs_cifs_bundle_YYYYmmdd_HHMMSS
  -d SEC      Total collection duration in seconds. Default: 600
  -i SEC      Snapshot interval in seconds. Default: 60
  -m MODE     Collection mode: basic, detail, full. Default: basic
  -n PID      Enter target PID's mount and network namespace for selected commands.
  -p LIST     Comma-separated port list for socket checks. Default: 111,2049,445,139
  --compress  Create tar.gz archive at the end if tar/gzip available.
  -h, --help  Show this help.

What this collects:
  RPC/NFS:
    - nfsstat, nfsiostat, mountstats if installed
    - /proc/net/rpc/* raw counters
    - /proc/self/mountstats
    - /proc/fs/nfsfs/* metadata when present
    - rpcinfo/showmount evidence when available
  CIFS/SMB:
    - /proc/fs/cifs/Stats, DebugData, open_files when present
    - /sys/module/cifs/parameters
    - smbstatus if installed
    - cifs mounts from findmnt/mount
  Common:
    - findmnt/mount/df
    - ss/netstat for RPC/NFS/CIFS ports
    - dmesg and journal kernel tails
    - ps/top/vmstat context

Safety:
  This script is read-only by default. It does not enable rpcdebug, CIFS debug,
  dynamic_debug, tracepoints, packet capture, or kernel debug flags.
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

run_ns() {
    if [ -n "$NETNS_PID" ]; then
        if have_cmd nsenter; then
            nsenter -t "$NETNS_PID" -m -n -- "$@"
        else
            "$@"
        fi
    else
        "$@"
    fi
}

run_ns_sh() {
    local cmd="$1"
    if [ -n "$NETNS_PID" ]; then
        if have_cmd nsenter; then
            nsenter -t "$NETNS_PID" -m -n -- bash -lc "$cmd"
        else
            bash -lc "$cmd"
        fi
    else
        bash -lc "$cmd"
    fi
}

safe_read() {
    local path="$1"
    if [ -r "$path" ]; then
        cat "$path" 2>/dev/null || true
    else
        echo "UNREADABLE_OR_NOT_PRESENT"
    fi
}

safe_copy_dir_files() {
    local src="$1"
    local dst="$2"
    mkdir -p "$dst" 2>/dev/null || return 0
    if [ -d "$src" ]; then
        find "$src" -maxdepth 2 -type f 2>/dev/null | while IFS= read -r f; do
            rel=${f#"$src"/}
            mkdir -p "$dst/$(dirname "$rel")" 2>/dev/null || true
            cat "$f" > "$dst/$rel" 2>/dev/null || echo "UNREADABLE: $f" > "$dst/$rel" 2>/dev/null || true
        done
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
            -n)
                [ "$#" -ge 2 ] || error_exit "-n requires PID"
                NETNS_PID=$2; shift 2 ;;
            -p)
                [ "$#" -ge 2 ] || error_exit "-p requires comma separated ports"
                PORTS=$2; shift 2 ;;
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

    if [ -n "$NETNS_PID" ]; then
        is_uint "$NETNS_PID" || error_exit "namespace PID must be numeric"
        [ -d "/proc/$NETNS_PID" ] || error_exit "PID does not exist: $NETNS_PID"
    fi

    if [ -z "$OUTDIR" ]; then
        OUTDIR="./rpc_nfs_cifs_bundle_$(date +%Y%m%d_%H%M%S)"
    fi
}

preflight_dirs() {
    mkdir -p "$OUTDIR" "$OUTDIR/static" "$OUTDIR/snapshots" "$OUTDIR/proc" "$OUTDIR/nfs" "$OUTDIR/cifs" "$OUTDIR/rpc" "$OUTDIR/logs" || \
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
        echo "ports=$PORTS"
        echo "netns_pid=${NETNS_PID:-none}"
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
        echo "[namespace]"
        if [ -n "$NETNS_PID" ]; then
            echo "target_pid=$NETNS_PID"
            ls -l "/proc/$NETNS_PID/ns/mnt" 2>/dev/null || true
            ls -l "/proc/$NETNS_PID/ns/net" 2>/dev/null || true
        else
            echo "host namespace"
            ls -l /proc/self/ns/mnt 2>/dev/null || true
            ls -l /proc/self/ns/net 2>/dev/null || true
        fi
        echo
        echo "[available commands]"
        for c in nfsstat nfsiostat mountstats rpcinfo showmount smbstatus ss netstat lsof fuser findmnt mount df journalctl dmesg ps top vmstat timeout nsenter; do
            if have_cmd "$c"; then
                echo "$c=YES ($(command -v "$c"))"
            else
                echo "$c=NO"
            fi
        done
        echo
        echo "[debug policy]"
        echo "rpcdebug=not modified"
        echo "cifs dynamic_debug=not modified"
        echo "tracepoints=not modified"
        echo "packet_capture=not enabled"
    } > "$meta"
}

collect_static_mounts() {
    {
        echo "[findmnt all]"
        run_ns_sh 'findmnt 2>/dev/null || true'
        echo
        echo "[findmnt nfs/cifs]"
        run_ns_sh 'findmnt -t nfs,nfs4,cifs 2>/dev/null || true'
        echo
        echo "[mount all]"
        run_ns_sh 'mount 2>/dev/null || true'
        echo
        echo "[mount nfs/cifs grep]"
        run_ns_sh 'mount 2>/dev/null | grep -Ei "type (nfs|nfs4|cifs)" || true'
        echo
        echo "[df -hT]"
        run_ns_sh 'df -hT 2>/dev/null || true'
        echo
        echo "[df -i]"
        run_ns_sh 'df -i 2>/dev/null || true'
    } > "$OUTDIR/static/mounts_filesystems.txt"
}

collect_static_module_params() {
    local out="$OUTDIR/static/module_params"
    mkdir -p "$out"

    for mod in sunrpc nfs nfsv3 nfsv4 nfsd lockd cifs dns_resolver fscache cachefiles; do
        if [ -d "/sys/module/$mod" ]; then
            mkdir -p "$out/$mod"
            echo "present" > "$out/$mod/module_present.txt"
            safe_copy_dir_files "/sys/module/$mod/parameters" "$out/$mod/parameters"
        else
            mkdir -p "$out/$mod"
            echo "not_present" > "$out/$mod/module_present.txt"
        fi
    done
}

collect_static_rpcdebug_status() {
    {
        echo "[sunrpc proc sys debug files]"
        for f in /proc/sys/sunrpc/*debug* /proc/sys/sunrpc/*_debug; do
            [ -e "$f" ] || continue
            echo "--- $f ---"
            safe_read "$f"
        done
        echo
        echo "[rpcdebug help/version if available]"
        if have_cmd rpcdebug; then
            rpcdebug -h 2>&1 || true
        else
            echo "rpcdebug not available"
        fi
        echo
        echo "Note: this collector does not enable rpcdebug flags."
    } > "$OUTDIR/static/rpcdebug_status.txt"
}

collect_static_rpcinfo() {
    {
        echo "[rpcinfo -p localhost]"
        if have_cmd rpcinfo; then
            run_ns rpcinfo -p localhost 2>&1 || true
            echo
            echo "[rpcinfo -p 127.0.0.1]"
            run_ns rpcinfo -p 127.0.0.1 2>&1 || true
        else
            echo "rpcinfo not available"
        fi
        echo
        echo "[showmount -e localhost]"
        if have_cmd showmount; then
            run_ns showmount -e localhost 2>&1 || true
        else
            echo "showmount not available"
        fi
    } > "$OUTDIR/static/rpcinfo_showmount.txt"
}

collect_static_cifs_context() {
    {
        echo "[/proc/fs/cifs directory]"
        if [ -d /proc/fs/cifs ]; then
            ls -la /proc/fs/cifs 2>&1 || true
        else
            echo "/proc/fs/cifs not present"
        fi
        echo
        echo "[cifs module parameters]"
        if [ -d /sys/module/cifs/parameters ]; then
            for f in /sys/module/cifs/parameters/*; do
                [ -f "$f" ] || continue
                echo "--- $f ---"
                safe_read "$f"
            done
        else
            echo "/sys/module/cifs/parameters not present"
        fi
    } > "$OUTDIR/static/cifs_context.txt"
}

collect_socket_ports() {
    local dir="$1"
    local socket_out="$dir/socket_ports.txt"
    : > "$socket_out"

    oldIFS=$IFS
    IFS=','
    for p in $PORTS; do
        p=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$p" ] || continue
        {
            echo "### port=$p"
            if have_cmd ss; then
                run_ns ss -tanp "sport = :$p or dport = :$p" 2>&1 || true
                run_ns ss -uanp "sport = :$p or dport = :$p" 2>&1 || true
            elif have_cmd netstat; then
                run_ns netstat -anp 2>/dev/null | grep -E "[:.]$p[[:space:]]" || true
            else
                echo "ss/netstat unavailable"
            fi
            if have_cmd fuser; then
                echo "[fuser tcp/$p]"
                run_ns fuser -n tcp "$p" 2>&1 || true
                echo "[fuser udp/$p]"
                run_ns fuser -n udp "$p" 2>&1 || true
            fi
            echo
        } >> "$socket_out"
    done
    IFS=$oldIFS
}

collect_proc_rpc_raw() {
    local dir="$1/proc_net_rpc"
    mkdir -p "$dir"
    if [ -d /proc/net/rpc ]; then
        for f in /proc/net/rpc/*; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            safe_read "$f" > "$dir/$base.txt"
        done
    else
        echo "/proc/net/rpc not present" > "$dir/not_present.txt"
    fi
}

collect_proc_nfs_cifs_raw() {
    local dir="$1/raw_proc_fs"
    mkdir -p "$dir"

    if [ -r /proc/self/mountstats ]; then
        cat /proc/self/mountstats > "$dir/proc_self_mountstats.txt" 2>/dev/null || true
    else
        echo "UNREADABLE_OR_NOT_PRESENT" > "$dir/proc_self_mountstats.txt"
    fi

    if [ -d /proc/fs/nfsfs ]; then
        safe_copy_dir_files /proc/fs/nfsfs "$dir/nfsfs"
    else
        mkdir -p "$dir/nfsfs"
        echo "/proc/fs/nfsfs not present" > "$dir/nfsfs/not_present.txt"
    fi

    if [ -d /proc/fs/cifs ]; then
        safe_copy_dir_files /proc/fs/cifs "$dir/cifs"
    else
        mkdir -p "$dir/cifs"
        echo "/proc/fs/cifs not present" > "$dir/cifs/not_present.txt"
    fi
}

collect_nfs_tools() {
    local dir="$1"
    {
        echo "[nfsstat -c]"
        if have_cmd nfsstat; then
            run_ns nfsstat -c 2>&1 || true
        else
            echo "nfsstat not available"
        fi
        echo
        echo "[nfsstat -m]"
        if have_cmd nfsstat; then
            run_ns nfsstat -m 2>&1 || true
        else
            echo "nfsstat not available"
        fi
        echo
        echo "[nfsiostat]"
        if have_cmd nfsiostat; then
            run_ns nfsiostat 2>&1 || true
        else
            echo "nfsiostat not available"
        fi
        echo
        echo "[mountstats]"
        if have_cmd mountstats; then
            run_ns mountstats 2>&1 || true
        else
            echo "mountstats command not available"
        fi
    } > "$dir/nfs_tools.txt"
}

collect_cifs_tools() {
    local dir="$1"
    {
        echo "[CIFS Stats]"
        safe_read /proc/fs/cifs/Stats
        echo
        echo "[CIFS DebugData]"
        safe_read /proc/fs/cifs/DebugData
        echo
        echo "[CIFS open_files]"
        safe_read /proc/fs/cifs/open_files
        echo
        echo "[smbstatus]"
        if have_cmd smbstatus; then
            smbstatus 2>&1 || true
        else
            echo "smbstatus not available"
        fi
    } > "$dir/cifs_tools.txt"
}

collect_runtime_context() {
    local dir="$1"
    {
        echo "[vmstat]"
        vmstat 1 2 2>&1 || true
        echo
        echo "[top]"
        top -b -n 1 2>&1 || true
        echo
        echo "[ps rpc/nfs/cifs related]"
        ps -eo pid,ppid,stat,comm,wchan:32,etime,args 2>/dev/null | grep -Ei 'rpc|nfs|cifs|smb|mount|kworker|ksmbd' || true
        echo
        echo "[dmesg nfs/cifs/rpc tail]"
        dmesg 2>/dev/null | grep -Ei 'nfs|cifs|smb|sunrpc|rpc|lockd|mount' | tail -n 300 || true
        echo
        echo "[journal kernel nfs/cifs/rpc tail]"
        if have_cmd journalctl; then
            journalctl -k --no-pager -n 500 2>/dev/null | grep -Ei 'nfs|cifs|smb|sunrpc|rpc|lockd|mount' || true
        else
            echo "journalctl not available"
        fi
    } > "$dir/runtime_context.txt"
}

collect_lsof_detail() {
    local dir="$1"
    [ "$MODE" = "basic" ] && return 0
    have_cmd lsof || return 0

    lsof -nP > "$dir/lsof_all.txt" 2>&1 || true
    lsof -nP -i > "$dir/lsof_network.txt" 2>&1 || true
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

    collect_nfs_tools "$dir"
    collect_cifs_tools "$dir"
    collect_socket_ports "$dir"
    collect_proc_rpc_raw "$dir"
    collect_proc_nfs_cifs_raw "$dir"
    collect_runtime_context "$dir"
    collect_lsof_detail "$dir"

    if [ "$MODE" = "full" ]; then
        safe_copy_dir_files /sys/module "$dir/sys_module_limited"
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
    collect_static_mounts
    collect_static_module_params
    collect_static_rpcdebug_status
    collect_static_rpcinfo
    collect_static_cifs_context

    log "INFO: output directory: $OUTDIR"
    log "INFO: mode=$MODE duration=$DURATION interval=$INTERVAL ports=$PORTS"

    local sample_id=0 now elapsed
    while :; do
        now=$(now_epoch)
        [ "$now" -ge "$end_epoch" ] && break
        elapsed=$((now - START_EPOCH))
        sample_id=$((sample_id + 1))
        collect_snapshot "$sample_id" "$elapsed"
        sleep "$INTERVAL"
    done

    {
        echo "completed_at_utc=$(now_utc)"
        echo "completed_at_epoch=$(now_epoch)"
        echo "samples_collected=$sample_id"
    } > "$OUTDIR/99_collection_end.txt"

    compress_output
    log "INFO: completed: $OUTDIR"
}

main "$@"
