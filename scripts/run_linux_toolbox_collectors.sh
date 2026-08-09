#!/usr/bin/env bash
# run_linux_toolbox_collectors.sh
# LinuxToolBox collector orchestrator.
#
# Newly included collectors:
#   mpstat        collect_mpstat_perf.sh
#   softnet       collect_softnet_perf.sh
#   lockup_kdump  enable_lockup_panic_for_kdump.sh
#
# Safety:
#   - sysrq_netconsole runs with --dry-run unless --enable-real-sysrq is used.
#   - tcpdump is excluded unless --enable-tcpdump or --only tcpdump is used.
#   - lockup_kdump is validation-only in the orchestrator. The runtime-changing
#     script is never applied automatically by this orchestrator or CI workflow.

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
SOFTNET_IFACES=""
SOCKET_PORTS="22,80,443"
RPC_PORTS="111,2049,445,139"
NETNS_PID=""
SKIP_UNAVAILABLE=1

COLLECTOR_ORDER="datastore firmware_memmap iomem meminfo mpstat rpc_nfs_cifs socket softnet sysrq_netconsole tcpdump vmstat lockup_kdump"

usage() {
    cat <<'EOF'
Usage:
  run_linux_toolbox_collectors.sh [options]

General options:
  -o, --out DIR              Parent output directory
  --script-dir DIR           Collector script directory. Default: ./scripts or current directory
  --profile PROFILE          smoke, basic, detail, full. Default: smoke
  -d, --duration SEC         Override duration
  -i, --interval SEC         Override interval
  --only LIST                Comma-separated collector keys
  --exclude LIST             Comma-separated collector keys to skip
  --continue-on-error        Continue after collector failure and exit 0
  --dry-run                  Print generated commands only
  --compress                 Enable supported collector compression and final archive
  --no-skip-unavailable      Treat unavailable kernel paths as failures
  --list                     List collector keys
  -h, --help                 Show help

Feature options:
  --enable-tcpdump           Include tcpdump in all-collector runs
  --tcpdump-iface IFACE      tcpdump interface. Default: auto
  --tcpdump-filter EXPR      tcpdump BPF filter
  --enable-real-sysrq        Permit real non-destructive SysRq collector writes
  --softnet-ifaces LIST      Comma-separated interfaces for softnet -I
  --socket-ports LIST        Ports for socket collector
  --rpc-ports LIST           Ports for RPC/NFS/CIFS collector
  --netns-pid PID            Namespace PID for supported collectors

Collector keys:
  datastore         collect_datastore_survival.sh
  firmware_memmap   collect_firmware_memmap_portable.sh
  iomem             collect_iomem_perf.sh
  meminfo           collect_meminfo_perf.sh
  mpstat            collect_mpstat_perf.sh
  rpc_nfs_cifs      collect_rpc_nfs_cifs_perf.sh
  socket            collect_socket_perf_bundle.sh
  softnet           collect_softnet_perf.sh
  sysrq_netconsole  collect_sysrq_netconsole_perf.sh
  tcpdump           collect_tcpdump_perf.sh
  vmstat            collect_vmstat_perf.sh
  lockup_kdump      enable_lockup_panic_for_kdump.sh, validation only

Profiles:
  smoke   duration=3, interval=1, basic mode
  basic   duration=60, interval=10, basic mode
  detail  duration=600, interval=60, detail mode
  full    duration=600, interval=60, full mode
EOF
}

log() { printf '%s\n' "$*" >&2; }
error_exit() { log "ERROR: $*"; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
now_epoch() { date +%s; }
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

contains_key() {
    local list=$1 key=$2 item oldifs=$IFS
    IFS=','
    for item in $list; do
        item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ "$item" = "$key" ]; then IFS=$oldifs; return 0; fi
    done
    IFS=$oldifs
    return 1
}

script_name_for_key() {
    case "$1" in
        datastore) echo collect_datastore_survival.sh ;;
        firmware_memmap) echo collect_firmware_memmap_portable.sh ;;
        iomem) echo collect_iomem_perf.sh ;;
        meminfo) echo collect_meminfo_perf.sh ;;
        mpstat) echo collect_mpstat_perf.sh ;;
        rpc_nfs_cifs) echo collect_rpc_nfs_cifs_perf.sh ;;
        socket) echo collect_socket_perf_bundle.sh ;;
        softnet) echo collect_softnet_perf.sh ;;
        sysrq_netconsole) echo collect_sysrq_netconsole_perf.sh ;;
        tcpdump) echo collect_tcpdump_perf.sh ;;
        vmstat) echo collect_vmstat_perf.sh ;;
        lockup_kdump) echo enable_lockup_panic_for_kdump.sh ;;
        *) return 1 ;;
    esac
}

mode_for_profile() {
    case "$PROFILE" in smoke|basic) echo basic;; detail) echo detail;; full) echo full;; esac
}

default_duration() { case "$PROFILE" in smoke) echo 3;; basic) echo 60;; detail|full) echo 600;; esac; }
default_interval() { case "$PROFILE" in smoke) echo 1;; basic) echo 10;; detail|full) echo 60;; esac; }

list_collectors() {
    local key
    for key in $COLLECTOR_ORDER; do printf '%-18s %s\n' "$key" "$(script_name_for_key "$key")"; done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o|--out) [ "$#" -ge 2 ] || error_exit "$1 requires DIR"; OUTDIR=$2; shift 2;;
            --script-dir) [ "$#" -ge 2 ] || error_exit "$1 requires DIR"; SCRIPT_DIR=$2; shift 2;;
            --profile) [ "$#" -ge 2 ] || error_exit "$1 requires PROFILE"; PROFILE=$2; shift 2;;
            -d|--duration) [ "$#" -ge 2 ] || error_exit "$1 requires SEC"; DURATION=$2; shift 2;;
            -i|--interval) [ "$#" -ge 2 ] || error_exit "$1 requires SEC"; INTERVAL=$2; shift 2;;
            --only) [ "$#" -ge 2 ] || error_exit "$1 requires LIST"; ONLY=$2; shift 2;;
            --exclude) [ "$#" -ge 2 ] || error_exit "$1 requires LIST"; EXCLUDE=$2; shift 2;;
            --continue-on-error) CONTINUE_ON_ERROR=1; shift;;
            --dry-run) DRY_RUN=1; shift;;
            --compress) COMPRESS=1; shift;;
            --no-skip-unavailable) SKIP_UNAVAILABLE=0; shift;;
            --enable-tcpdump) ENABLE_TCPDUMP=1; shift;;
            --tcpdump-iface) [ "$#" -ge 2 ] || error_exit "$1 requires IFACE"; TCPDUMP_IFACE=$2; shift 2;;
            --tcpdump-filter) [ "$#" -ge 2 ] || error_exit "$1 requires EXPR"; TCPDUMP_FILTER=$2; shift 2;;
            --enable-real-sysrq) ENABLE_REAL_SYSRQ=1; shift;;
            --softnet-ifaces) [ "$#" -ge 2 ] || error_exit "$1 requires LIST"; SOFTNET_IFACES=$2; shift 2;;
            --socket-ports) [ "$#" -ge 2 ] || error_exit "$1 requires LIST"; SOCKET_PORTS=$2; shift 2;;
            --rpc-ports) [ "$#" -ge 2 ] || error_exit "$1 requires LIST"; RPC_PORTS=$2; shift 2;;
            --netns-pid) [ "$#" -ge 2 ] || error_exit "$1 requires PID"; NETNS_PID=$2; shift 2;;
            --list) list_collectors; exit 0;;
            -h|--help) usage; exit 0;;
            *) error_exit "unknown option: $1";;
        esac
    done
}

validate_args() {
    case "$PROFILE" in smoke|basic|detail|full) :;; *) error_exit "invalid profile: $PROFILE";; esac
    [ -n "$DURATION" ] || DURATION=$(default_duration)
    [ -n "$INTERVAL" ] || INTERVAL=$(default_interval)
    is_uint "$DURATION" && [ "$DURATION" -gt 0 ] || error_exit "duration must be positive integer"
    is_uint "$INTERVAL" && [ "$INTERVAL" -gt 0 ] || error_exit "interval must be positive integer"
    if [ -n "$NETNS_PID" ]; then
        is_uint "$NETNS_PID" || error_exit "netns PID must be numeric"
        [ -d "/proc/$NETNS_PID" ] || error_exit "netns PID does not exist: $NETNS_PID"
    fi
}

resolve_script_dir() {
    [ -n "$SCRIPT_DIR" ] && return
    [ -d ./scripts ] && SCRIPT_DIR=./scripts || SCRIPT_DIR=.
}

should_run_key() {
    local key=$1
    [ -z "$ONLY" ] || contains_key "$ONLY" "$key" || return 1
    if [ -n "$EXCLUDE" ] && contains_key "$EXCLUDE" "$key"; then return 1; fi
    if [ "$key" = tcpdump ] && [ "$ENABLE_TCPDUMP" -ne 1 ]; then
        [ -n "$ONLY" ] && contains_key "$ONLY" tcpdump && return 0
        return 1
    fi
    return 0
}

build_command() {
    local key=$1 script=$2 mode script_path collector_out cmd sysrq_mode
    mode=$(mode_for_profile)
    script_path="$SCRIPT_DIR/$script"
    collector_out="$OUTDIR/collectors/$key"

    case "$key" in
        datastore)
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -o \"$collector_out\""
            [ "$COMPRESS" -eq 1 ] && cmd="$cmd --compress";;
        firmware_memmap)
            mkdir -p "$collector_out" 2>/dev/null || true
            cmd="\"$script_path\" \"$collector_out/firmware_memmap.out\"";;
        iomem|meminfo|mpstat|vmstat)
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -m $mode -o \"$collector_out\""
            [ "$COMPRESS" -eq 1 ] && cmd="$cmd --compress";;
        softnet)
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -m $mode -o \"$collector_out\""
            [ -n "$SOFTNET_IFACES" ] && cmd="$cmd -I \"$SOFTNET_IFACES\""
            [ "$COMPRESS" -eq 1 ] && cmd="$cmd --compress";;
        rpc_nfs_cifs)
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -m $mode -p $RPC_PORTS -o \"$collector_out\""
            [ -n "$NETNS_PID" ] && cmd="$cmd -n $NETNS_PID"
            [ "$COMPRESS" -eq 1 ] && cmd="$cmd --compress";;
        socket)
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -p $SOCKET_PORTS -o \"$collector_out\""
            [ -n "$NETNS_PID" ] && cmd="$cmd -n $NETNS_PID";;
        sysrq_netconsole)
            sysrq_mode=$mode
            [ "$sysrq_mode" = full ] && sysrq_mode=full-every-interval
            cmd="\"$script_path\" -d $DURATION -i $INTERVAL -m $sysrq_mode -o \"$collector_out\" --netconsole-remote 10.0.0.10:6666 --netconsole-iface eth0"
            [ "$ENABLE_REAL_SYSRQ" -ne 1 ] && cmd="$cmd --dry-run";;
        tcpdump)
            cmd="\"$script_path\" -I $TCPDUMP_IFACE -d $DURATION -i $INTERVAL -c 1 -m $mode -o \"$collector_out\""
            [ -n "$TCPDUMP_FILTER" ] && cmd="$cmd -f '$TCPDUMP_FILTER'"
            [ "$COMPRESS" -eq 1 ] && cmd="$cmd --compress";;
        lockup_kdump)
            mkdir -p "$collector_out" 2>/dev/null || true
            cmd="sh -n \"$script_path\" && grep -nE 'require_root|check_kdump|show_current|show_planned|apply_settings|verify_settings' \"$script_path\" > \"$collector_out/validation.txt\"";;
        *) return 1;;
    esac
    printf '%s' "$cmd"
}

prepare_script() {
    local script_path=$1
    [ -f "$script_path" ] || return 1
    sed -i 's/\r$//' "$script_path" 2>/dev/null || true
    chmod +x "$script_path" 2>/dev/null || true
    case "$script_path" in
        *.sh) sh -n "$script_path" 2>/dev/null || bash -n "$script_path" 2>/dev/null || return 2;;
    esac
    return 0
}

is_soft_unavailable() {
    local key=$1 stderr_file=$2
    [ "$SKIP_UNAVAILABLE" -eq 1 ] || return 1
    case "$key" in
        firmware_memmap)
            grep -E '(/sys/firmware/memmap does not exist|no numeric entries found under /sys/firmware/memmap)' "$stderr_file" >/dev/null 2>&1 && return 0;;
    esac
    return 1
}

run_one() {
    local key=$1 script script_path result_dir prep_rc cmd rc soft_status
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
        echo status=missing_script >> "$result_dir/meta.txt"
        echo "MISSING: $script_path" > "$result_dir/stderr.txt"
        return 10
    fi

    prepare_script "$script_path"; prep_rc=$?
    if [ "$prep_rc" -ne 0 ]; then
        echo status=prepare_failed >> "$result_dir/meta.txt"
        echo "prepare_rc=$prep_rc" >> "$result_dir/meta.txt"
        return 11
    fi

    cmd=$(build_command "$key" "$script") || return 12
    echo "$cmd" > "$result_dir/command.txt"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo status=dry_run >> "$result_dir/meta.txt"
        echo "DRYRUN: $cmd" | tee "$result_dir/stdout.txt"
        return 0
    fi

    log "INFO: running [$key]"
    bash -lc "$cmd" > "$result_dir/stdout.txt" 2> "$result_dir/stderr.txt"; rc=$?

    soft_status=""
    if [ "$rc" -ne 0 ] && is_soft_unavailable "$key" "$result_dir/stderr.txt"; then
        rc=0; soft_status=soft_skipped_unavailable
    fi

    {
        echo "end_utc=$(now_utc)"
        echo "end_epoch=$(now_epoch)"
        echo "exit_code=$rc"
        if [ -n "$soft_status" ]; then echo "status=$soft_status"
        elif [ "$rc" -eq 0 ]; then echo status=success
        else echo status=failed; fi
    } >> "$result_dir/meta.txt"
    return "$rc"
}

write_run_metadata() {
    mkdir -p "$OUTDIR"
    {
        echo orchestrator=run_linux_toolbox_collectors.sh
        echo "started_at_utc=$(now_utc)"
        echo "started_at_epoch=$(now_epoch)"
        echo "script_dir=$SCRIPT_DIR"
        echo "profile=$PROFILE"
        echo "duration=$DURATION"
        echo "interval=$INTERVAL"
        echo "only=${ONLY:-none}"
        echo "exclude=${EXCLUDE:-none}"
        echo "softnet_ifaces=${SOFTNET_IFACES:-auto}"
        echo "lockup_kdump_mode=validation_only"
        uname -a
        [ -r /etc/os-release ] && cat /etc/os-release || true
    } > "$OUTDIR/00_orchestrator_metadata.txt"
}

write_final_summary() {
    local rc=$1 f
    {
        echo "completed_at_utc=$(now_utc)"
        echo "overall_exit_code=$rc"
        for f in "$OUTDIR"/results/*/meta.txt; do [ -f "$f" ] && { echo "--- $f ---"; cat "$f"; }; done
    } > "$OUTDIR/99_orchestrator_summary.txt"
}

compress_final_output() {
    [ "$COMPRESS" -eq 1 ] || return 0
    have_cmd tar && have_cmd gzip || return 0
    local parent base
    parent=$(dirname "$OUTDIR"); base=$(basename "$OUTDIR")
    (cd "$parent" && tar -czf "${OUTDIR}.tar.gz" "$base") 2>/dev/null || true
}

main() {
    local key rc overall_rc=0 ran_any=0
    parse_args "$@"
    validate_args
    resolve_script_dir
    write_run_metadata

    for key in $COLLECTOR_ORDER; do
        should_run_key "$key" || continue
        ran_any=1; rc=0
        run_one "$key" || rc=$?
        if [ "$rc" -ne 0 ]; then
            overall_rc=$rc
            log "WARN: collector failed: $key rc=$rc"
            [ "$CONTINUE_ON_ERROR" -eq 1 ] || break
        fi
    done

    [ "$ran_any" -eq 1 ] || overall_rc=20
    write_final_summary "$overall_rc"
    compress_final_output
    [ "$CONTINUE_ON_ERROR" -eq 1 ] && exit 0
    exit "$overall_rc"
}

main "$@"
