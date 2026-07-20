#!/usr/bin/env bash
# run_linux_toolbox_collectors.sh
#
# Orchestrator for LinuxToolBox collector scripts.
#
# Purpose:
#   - Run multiple collector scripts in one command.
#   - Allow running all collectors or selected collectors with --only/--exclude.
#   - Provide safe CI/smoke profiles with short duration/interval values.
#   - Keep each collector output isolated under one parent output directory.
#   - Record command, exit code, start/end timestamps, and logs per collector.
#
# Important CI behavior:
#   GitHub Actions often executes shell steps with errexit semantics.  This
#   orchestrator intentionally disables errexit and handles each collector exit
#   code explicitly so --continue-on-error works as expected.
#

set +e
set -u
umask 077
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR=""
OUTDIR="./linux_toolbox_bundle_$(date +%Y%m%d_%H%M%S)"
PROFILE="smoke"
DURATION=""
INTERVAL=""
ONLY=""
EXCLUDE=""
DRY_RUN=0
CONTINUE_ON_ERROR=0
COMPRESS=0
ENABLE_TCPDUMP=0
ENABLE_REAL_SYSRQ=0
TCPDUMP_IFACE="auto"
TCPDUMP_FILTER=""
SOCKET_PORTS="22,80,443"
RPC_PORTS="111,2049,445,139"
NETNS_PID=""
SKIP_UNAVAILABLE=1

COLLECTOR_ORDER="datastore firmware_memmap iomem meminfo rpc_nfs_cifs socket sysrq_netconsole tcpdump vmstat"

usage() {
    cat <<'EOF'
Usage:
  run_linux_toolbox_collectors.sh [options]

General options:
  -o, --out DIR              Parent output directory. Default: ./linux_toolbox_bundle_YYYYmmdd_HHMMSS
  --script-dir DIR           Directory containing collector scripts. Default: ./scripts if present, else current directory
  --profile PROFILE          smoke, basic, detail, full. Default: smoke
  -d, --duration SEC         Override collector duration where supported
  -i, --interval SEC         Override collector interval where supported
  --only LIST                Comma-separated collector keys to run
  --exclude LIST             Comma-separated collector keys to skip
  --continue-on-error        Do not fail overall run if a collector fails
  --dry-run                  Print commands but do not execute collectors
  --compress                 Ask supported collectors to compress their own output, and create final tar.gz
  --no-skip-unavailable      Do not soft-skip collectors when required kernel paths are unavailable
  --list                     List known collector keys and script filenames
  -h, --help                 Show help

Safety / feature options:
  --enable-tcpdump           Include tcpdump collector. By default tcpdump is skipped unless explicitly selected by --only or enabled here
  --tcpdump-iface IFACE      tcpdump interface. Default: auto
  --tcpdump-filter EXPR      tcpdump BPF filter
  --enable-real-sysrq        Allow sysrq collector to write to /proc/sysrq-trigger. Default is dry-run for sysrq collector
  --socket-ports LIST        Ports for socket collector. Default: 22,80,443
  --rpc-ports LIST           Ports for RPC/NFS/CIFS collector. Default: 111,2049,445,139
  --netns-pid PID            Namespace PID for collectors that support namespace mode

Collector keys:
  datastore         collect_datastore_survival.sh
  firmware_memmap   collect_firmware_memmap_portable.sh
  iomem             collect_iomem_perf.sh
  meminfo           collect_meminfo_perf.sh
  rpc_nfs_cifs      collect_rpc_nfs_cifs_perf.sh
  socket            collect_socket_perf_bundle.sh
  sysrq_netconsole  collect_sysrq_netconsole_perf.sh
  tcpdump           collect_tcpdump_perf.sh
  vmstat            collect_vmstat_perf.sh

Profiles:
  smoke   Short CI-safe run, usually duration=3, interval=1
  basic   duration=60, interval=10, collector mode basic
  detail  duration=600, interval=60, collector mode detail
  full    duration=600, interval=60, collector mode full where supported

Notes:
  - SysRq collector is executed with --dry-run unless --enable-real-sysrq is specified.
  - tcpdump collector is skipped by default unless --enable-tcpdump or --only tcpdump is used.
  - firmware_memmap depends on /sys/firmware/memmap. In containers this path is commonly absent, so it is soft-skipped by default.
EOF
}

log() { printf '%s\n' "$*" >&2; }
error_exit() { log "ERROR: $*"; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
now_epoch() { date +%s; }

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

contains_key() {
    list=$1
    key=$2
    oldifs=$IFS
    IFS=','
    for item in $list; do
        item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ "$item" = "$key" ] && { IFS=$oldifs; return 0; }
    done
    IFS=$oldifs
    return 1
}

script_name_for_key() {
    case "$1" in
        datastore) echo "collect_datastore_survival.sh" ;;
        firmware_memmap) echo "collect_firmware_memmap_portable.sh" ;;
        iomem) echo "collect_iomem_perf.sh" ;;
        meminfo) echo "collect_meminfo_perf.sh" ;;
        rpc_nfs_cifs) echo "collect_rpc_nfs_cifs_perf.sh" ;;
        socket) echo "collect_socket_perf_bundle.sh" ;;
        sysrq_netconsole) echo "collect_sysrq_netconsole_perf.sh" ;;
        tcpdump) echo "collect_tcpdump_perf.sh" ;;
        vmstat) echo "collect_vmstat_perf.sh" ;;
        *) return 1 ;;
    esac
}

mode_for_profile() {
    case "$PROFILE" in
        smoke|basic) echo "basic" ;;
        detail) echo "detail" ;;
        full) echo "full" ;;
        *) echo "basic" ;;
    esac
}

default_duration() {
    case "$PROFILE" in
        smoke) echo 3 ;;
        basic) echo 60 ;;
        detail|full) echo 600 ;;
        *) echo 3 ;;
    esac
}

default_interval() {
    case "$PROFILE" in
        smoke) echo 1 ;;
        basic) echo 10 ;;
        detail|full) echo 60 ;;
        *) echo 1 ;;
    esac
}

resolve_script_dir() {
    [ -n "$SCRIPT_DIR" ] && return 0
    if [ -d ./scripts ]; then
        SCRIPT_DIR=./scripts
    else
        SCRIPT_DIR=.
    fi
}

list_collectors() {
    for key in $COLLECTOR_ORDER; do
        printf '%-18s %s\n' "$key" "$(script_name_for_key "$key")"
    done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o|--out)
                [ "$#" -ge 2 ] || error_exit "$1 requires directory"
                OUTDIR=$2; shift 2 ;;
            --script-dir)
                [ "$#" -ge 2 ] || error_exit "--script-dir requires directory"
                SCRIPT_DIR=$2; shift 2 ;;
            --profile)
                [ "$#" -ge 2 ] || error_exit "--profile requires value"
                PROFILE=$2; shift 2 ;;
            -d|--duration)
                [ "$#" -ge 2 ] || error_exit "$1 requires seconds"
                DURATION=$2; shift 2 ;;
            -i|--interval)
                [ "$#" -ge 2 ] || error_exit "$1 requires seconds"
                INTERVAL=$2; shift 2 ;;
            --only)
                [ "$#" -ge 2 ] || error_exit "--only requires comma-separated list"
                ONLY=$2; shift 2 ;;
            --exclude)
                [ "$#" -ge 2 ] || error_exit "--exclude requires comma-separated list"
                EXCLUDE=$2; shift 2 ;;
            --continue-on-error)
                CONTINUE_ON_ERROR=1; shift ;;
            --dry-run)
                DRY_RUN=1; shift ;;
            --compress)
                COMPRESS=1; shift ;;
            --no-skip-unavailable)
                SKIP_UNAVAILABLE=0; shift ;;
            --enable-tcpdump)
                ENABLE_TCPDUMP=1; shift ;;
            --tcpdump-iface)
                [ "$#" -ge 2 ] || error_exit "--tcpdump-iface requires interface"
                TCPDUMP_IFACE=$2; shift 2 ;;
            --tcpdump-filter)
                [ "$#" -ge 2 ] || error_exit "--tcpdump-filter requires expression"
                TCPDUMP_FILTER=$2; shift 2 ;;
            --enable-real-sysrq)
                ENABLE_REAL_SYSRQ=1; shift ;;
            --socket-ports)
                [ "$#" -ge 2 ] || error_exit "--socket-ports requires list"
                SOCKET_PORTS=$2; shift 2 ;;
            --rpc-ports)
                [ "$#" -ge 2 ] || error_exit "--rpc-ports requires list"
                RPC_PORTS=$2; shift 2 ;;
            --netns-pid)
                [ "$#" -ge 2 ] || error_exit "--netns-pid requires PID"
                NETNS_PID=$2; shift 2 ;;
            --list)
                list_collectors; exit 0 ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                error_exit "unknown option: $1" ;;
        esac
    done
}

validate_args() {
    case "$PROFILE" in
        smoke|basic|detail|full) : ;;
        *) error_exit "invalid profile: $PROFILE" ;;
    esac

    [ -n "$DURATION" ] || DURATION=$(default_duration)
    [ -n "$INTERVAL" ] || INTERVAL=$(default_interval)

    is_uint "$DURATION" || error_exit "duration must be integer"
    is_uint "$INTERVAL" || error_exit "interval must be integer"
    [ "$DURATION" -gt 0 ] || error_exit "duration must be > 0"
    [ "$INTERVAL" -gt 0 ] || error_exit "interval must be > 0"

    if [ -n "$NETNS_PID" ]; then
        is_uint "$NETNS_PID" || error_exit "netns pid must be numeric"
        [ -d "/proc/$NETNS_PID" ] || error_exit "netns pid does not exist: $NETNS_PID"
    fi
}

should_run_key() {
    key=$1

    if [ -n "$ONLY" ]; then
        contains_key "$ONLY" "$key" || return 1
    fi

    if [ -n "$EXCLUDE" ] && contains_key "$EXCLUDE" "$key"; then
        return 1
    fi

    if [ "$key" = "tcpdump" ] && [ "$ENABLE_TCPDUMP" -ne 1 ]; then
        if [ -n "$ONLY" ] && contains_key "$ONLY" "tcpdump"; then
            return 0
        fi
        return 1
    fi

    return 0
}

build_command() {
    key=$1
    script=$2
    mode=$(mode_for_profile)
    script_path="$SCRIPT_DIR/$script"
    collector_out="$OUTDIR/collectors/$key"

    case "$key" in
        datastore)
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -o \"$collector_out\""
            [ "$COMPRESS" -eq 1 ] && cmd="$cmd --compress"
            ;;
        firmware_memmap)
            mkdir -p "$collector_out" 2>/dev/null || true
            cmd="\"$script_path\" \"$collector_out/firmware_memmap.out\""
            ;;
        iomem|meminfo|vmstat)
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -m $mode -o \"$collector_out\""
            [ "$COMPRESS" -eq 1 ] && cmd="$cmd --compress"
            ;;
        rpc_nfs_cifs)
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -m $mode -p $RPC_PORTS -o \"$collector_out\""
            [ -n "$NETNS_PID" ] && cmd="$cmd -n $NETNS_PID"
            [ "$COMPRESS" -eq 1 ] && cmd="$cmd --compress"
            ;;
        socket)
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -p $SOCKET_PORTS -o \"$collector_out\""
            [ -n "$NETNS_PID" ] && cmd="$cmd -n $NETNS_PID"
            ;;
        sysrq_netconsole)
            sysrq_mode=$mode
            [ "$sysrq_mode" = "full" ] && sysrq_mode="full-every-interval"
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -m $sysrq_mode -o \"$collector_out\" --netconsole-remote 10.0.0.10:6666 --netconsole-iface eth0"
            [ "$ENABLE_REAL_SYSRQ" -ne 1 ] && cmd="$cmd --dry-run"
            ;;
        tcpdump)
            cmd="\"$script_path\" -I $TCPDUMP_IFACE -d $DURATION -i $INTERVAL -c 1 -m $mode -o \"$collector_out\""
            [ -n "$TCPDUMP_FILTER" ] && cmd="$cmd -f '$TCPDUMP_FILTER'"
            [ "$COMPRESS" -eq 1 ] && cmd="$cmd --compress"
            ;;
        *) return 1 ;;
    esac

    printf '%s' "$cmd"
}

prepare_script() {
    script_path=$1
    [ -f "$script_path" ] || return 1
    sed -i 's/\r$//' "$script_path" 2>/dev/null || true
    chmod +x "$script_path" 2>/dev/null || true
    bash -n "$script_path" 2>/dev/null || return 2
    return 0
}

is_soft_unavailable() {
    key=$1
    stderr_file=$2
    [ "$SKIP_UNAVAILABLE" -eq 1 ] || return 1

    case "$key" in
        firmware_memmap)
            grep -E '(/sys/firmware/memmap does not exist|no numeric entries found under /sys/firmware/memmap)' "$stderr_file" >/dev/null 2>&1 && return 0
            ;;
    esac
    return 1
}

run_one() {
    key=$1
    script=$(script_name_for_key "$key") || return 1
    script_path="$SCRIPT_DIR/$script"
    result_dir="$OUTDIR/results/$key"
    mkdir -p "$result_dir" "$OUTDIR/collectors" || return 1

    {
        echo "collector=$key"
        echo "script=$script_path"
        echo "start_utc=$(now_utc)"
        echo "start_epoch=$(now_epoch)"
    } > "$result_dir/meta.txt"

    if [ ! -f "$script_path" ]; then
        echo "status=missing_script" >> "$result_dir/meta.txt"
        echo "MISSING: $script_path" > "$result_dir/stderr.txt"
        return 10
    fi

    prepare_script "$script_path"
    prep_rc=$?
    if [ "$prep_rc" -ne 0 ]; then
        echo "status=prepare_failed" >> "$result_dir/meta.txt"
        echo "prepare_rc=$prep_rc" >> "$result_dir/meta.txt"
        echo "PREPARE FAILED: $script_path" > "$result_dir/stderr.txt"
        return 11
    fi

    cmd=$(build_command "$key" "$script") || return 12
    echo "$cmd" > "$result_dir/command.txt"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "status=dry_run" >> "$result_dir/meta.txt"
        echo "DRYRUN: $cmd" | tee "$result_dir/stdout.txt"
        return 0
    fi

    log "INFO: running [$key]"
    log "INFO: command: $cmd"

    bash -lc "$cmd" > "$result_dir/stdout.txt" 2> "$result_dir/stderr.txt"
    rc=$?

    if [ "$rc" -ne 0 ] && is_soft_unavailable "$key" "$result_dir/stderr.txt"; then
        rc=0
        soft_status="soft_skipped_unavailable"
    else
        soft_status=""
    fi

    {
        echo "end_utc=$(now_utc)"
        echo "end_epoch=$(now_epoch)"
        echo "exit_code=$rc"
        if [ -n "$soft_status" ]; then
            echo "status=$soft_status"
        elif [ "$rc" -eq 0 ]; then
            echo "status=success"
        else
            echo "status=failed"
        fi
    } >> "$result_dir/meta.txt"

    return "$rc"
}

write_run_metadata() {
    mkdir -p "$OUTDIR"
    {
        echo "orchestrator=run_linux_toolbox_collectors.sh"
        echo "started_at_utc=$(now_utc)"
        echo "started_at_epoch=$(now_epoch)"
        echo "script_dir=$SCRIPT_DIR"
        echo "outdir=$OUTDIR"
        echo "profile=$PROFILE"
        echo "duration=$DURATION"
        echo "interval=$INTERVAL"
        echo "only=${ONLY:-none}"
        echo "exclude=${EXCLUDE:-none}"
        echo "dry_run=$DRY_RUN"
        echo "continue_on_error=$CONTINUE_ON_ERROR"
        echo "skip_unavailable=$SKIP_UNAVAILABLE"
        echo "enable_tcpdump=$ENABLE_TCPDUMP"
        echo "enable_real_sysrq=$ENABLE_REAL_SYSRQ"
        echo "tcpdump_iface=$TCPDUMP_IFACE"
        echo "socket_ports=$SOCKET_PORTS"
        echo "rpc_ports=$RPC_PORTS"
        echo "netns_pid=${NETNS_PID:-none}"
        echo
        echo "[system]"
        uname -a
        echo
        echo "[os-release]"
        [ -r /etc/os-release ] && cat /etc/os-release || echo "not available"
    } > "$OUTDIR/00_orchestrator_metadata.txt"
}

write_final_summary() {
    rc=$1
    {
        echo "completed_at_utc=$(now_utc)"
        echo "completed_at_epoch=$(now_epoch)"
        echo "overall_exit_code=$rc"
        echo
        echo "[collector results]"
        for f in "$OUTDIR"/results/*/meta.txt; do
            [ -f "$f" ] || continue
            echo "--- $f ---"
            cat "$f"
        done
    } > "$OUTDIR/99_orchestrator_summary.txt"
}

compress_final_output() {
    [ "$COMPRESS" -eq 1 ] || return 0
    have_cmd tar || { log "WARN: tar not available; skip final compression"; return 0; }
    have_cmd gzip || { log "WARN: gzip not available; skip final compression"; return 0; }
    parent=$(dirname "$OUTDIR")
    base=$(basename "$OUTDIR")
    archive="${OUTDIR}.tar.gz"
    (cd "$parent" && tar -czf "$archive" "$base") 2>/dev/null || log "WARN: final compression failed"
}

main() {
    parse_args "$@"
    validate_args
    resolve_script_dir
    write_run_metadata

    log "INFO: output directory: $OUTDIR"
    log "INFO: script directory: $SCRIPT_DIR"
    log "INFO: profile=$PROFILE duration=$DURATION interval=$INTERVAL"

    overall_rc=0
    ran_any=0

    for key in $COLLECTOR_ORDER; do
        should_run_key "$key" || continue
        ran_any=1
        rc=0
        run_one "$key" || rc=$?
        if [ "$rc" -ne 0 ]; then
            overall_rc=$rc
            log "WARN: collector failed: $key rc=$rc"
            if [ "$CONTINUE_ON_ERROR" -ne 1 ]; then
                break
            fi
        fi
    done

    if [ "$ran_any" -eq 0 ]; then
        log "WARN: no collectors selected"
        overall_rc=20
    fi

    write_final_summary "$overall_rc"
    compress_final_output

    if [ "$CONTINUE_ON_ERROR" -eq 1 ]; then
        exit 0
    fi
    exit "$overall_rc"
}

main "$@"
