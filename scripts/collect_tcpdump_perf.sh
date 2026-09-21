#!/usr/bin/env bash
# collect_tcpdump_perf.sh
#
# tcpdump-oriented packet evidence collector.
#
# Purpose:
#   - Collect packet capture evidence with bounded duration and interval.
#   - Support a specific interface or "any".
#   - Validate whether tcpdump and requested interface are available.
#   - Optionally apply packet size min/max filters.
#   - Save metadata, interface context, socket context, and per-snapshot pcap files.
#
# Default:
#   - 10 minutes total duration
#   - 60 seconds interval
#   - 50 seconds tcpdump capture per interval
#   - interface: auto, prefer "any" if supported, otherwise first non-loopback interface
#   - snaplen: 160 bytes by default for low overhead evidence
#
# Supported targets:
#   Ubuntu 22.04/24.04, Debian 11/12, Oracle Linux, RHEL 8/9, SLES 12 SP5/15 SP6
#
# Notes:
#   - Requires root or CAP_NET_RAW/CAP_NET_ADMIN for packet capture.
#   - This script does not modify network configuration.
#   - Output may contain sensitive network metadata. Handle captures carefully.
#
# Examples:
#   sudo ./collect_tcpdump_perf.sh -o /var/tmp/tcpdump_bundle
#   sudo ./collect_tcpdump_perf.sh -I eth0 -d 600 -i 60 -c 50 -o /var/tmp/tcpdump_eth0
#   sudo ./collect_tcpdump_perf.sh -I any -f 'host 10.0.0.10 and port 2049' -o /var/tmp/nfs_pcap
#   sudo ./collect_tcpdump_perf.sh --min-len 100 --max-len 1500 -I any -o /var/tmp/size_filtered
#   sudo ./collect_tcpdump_perf.sh --list-interfaces

set -u
umask 077
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

DURATION=600
INTERVAL=60
CAPTURE_SECS=50
OUTDIR=""
IFACE="auto"
FILTER=""
SNAPLEN=160
MAX_FILE_MB=100
MIN_LEN=""
MAX_LEN=""
COMPRESS=0
LIST_ONLY=0
MODE="basic"
SCRIPT_NAME=$(basename "$0")
START_EPOCH=""

usage() {
    cat <<'EOF'
Usage:
  collect_tcpdump_perf.sh [options]

Options:
  -o DIR      Output directory. Default: ./tcpdump_bundle_YYYYmmdd_HHMMSS
  -I IFACE    Capture interface. Use specific interface, "any", or "auto". Default: auto
  -d SEC      Total collection duration in seconds. Default: 600
  -i SEC      Collection interval in seconds. Default: 60
  -c SEC      tcpdump capture seconds per interval. Default: min(interval-5, 50)
  -s BYTES    tcpdump snaplen. Default: 160. Use 0 for full packet capture.
  -f FILTER   tcpdump BPF filter expression. Example: 'host 10.0.0.10 and port 2049'
  --min-len N Add packet length lower-bound filter using tcpdump 'greater N'
  --max-len N Add packet length upper-bound filter using tcpdump 'less N'
  --max-file-mb N
              Expected per-pcap size warning threshold metadata only. Default: 100
  -m MODE     Collection mode: basic, detail, full. Default: basic
  --list-interfaces
              List interfaces detected by tcpdump -D and exit.
  --compress  Create tar.gz archive at the end if tar/gzip available.
  -h, --help  Show help.

Modes:
  basic  : pcap + metadata + ip/route/link context at start/end
  detail : basic + ss/netstat + ethtool stats per snapshot when available
  full   : detail + /proc/net raw files per snapshot

Min/max packet size filtering:
  --min-len N is translated to BPF: greater N
  --max-len N is translated to BPF: less N
  If both are used, both conditions are ANDed with the user filter.

Interface policy:
  -I any   : use tcpdump any device only if tcpdump reports/supports it
  -I auto  : prefer any if available; otherwise first non-loopback interface
  -I eth0  : require that interface to exist
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

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o)
                [ "$#" -ge 2 ] || error_exit "-o requires directory"
                OUTDIR=$2; shift 2 ;;
            -I)
                [ "$#" -ge 2 ] || error_exit "-I requires interface"
                IFACE=$2; shift 2 ;;
            -d)
                [ "$#" -ge 2 ] || error_exit "-d requires seconds"
                DURATION=$2; shift 2 ;;
            -i)
                [ "$#" -ge 2 ] || error_exit "-i requires seconds"
                INTERVAL=$2; shift 2 ;;
            -c)
                [ "$#" -ge 2 ] || error_exit "-c requires seconds"
                CAPTURE_SECS=$2; shift 2 ;;
            -s)
                [ "$#" -ge 2 ] || error_exit "-s requires snaplen"
                SNAPLEN=$2; shift 2 ;;
            -f)
                [ "$#" -ge 2 ] || error_exit "-f requires filter expression"
                FILTER=$2; shift 2 ;;
            --min-len)
                [ "$#" -ge 2 ] || error_exit "--min-len requires integer"
                MIN_LEN=$2; shift 2 ;;
            --max-len)
                [ "$#" -ge 2 ] || error_exit "--max-len requires integer"
                MAX_LEN=$2; shift 2 ;;
            --max-file-mb)
                [ "$#" -ge 2 ] || error_exit "--max-file-mb requires integer"
                MAX_FILE_MB=$2; shift 2 ;;
            -m)
                [ "$#" -ge 2 ] || error_exit "-m requires mode"
                MODE=$2; shift 2 ;;
            --list-interfaces)
                LIST_ONLY=1; shift ;;
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
    is_uint "$CAPTURE_SECS" || error_exit "capture seconds must be integer"
    is_uint "$SNAPLEN" || error_exit "snaplen must be integer"
    is_uint "$MAX_FILE_MB" || error_exit "max-file-mb must be integer"
    [ -z "$MIN_LEN" ] || is_uint "$MIN_LEN" || error_exit "min-len must be integer"
    [ -z "$MAX_LEN" ] || is_uint "$MAX_LEN" || error_exit "max-len must be integer"

    [ "$DURATION" -gt 0 ] || error_exit "duration must be > 0"
    [ "$INTERVAL" -gt 0 ] || error_exit "interval must be > 0"
    [ "$CAPTURE_SECS" -gt 0 ] || error_exit "capture seconds must be > 0"

    case "$MODE" in
        basic|detail|full) : ;;
        *) error_exit "invalid mode: $MODE" ;;
    esac

    if [ "$CAPTURE_SECS" -gt "$INTERVAL" ]; then
        log "WARN: capture seconds ($CAPTURE_SECS) is greater than interval ($INTERVAL). Samples may overlap in time."
    fi

    if [ -n "$MIN_LEN" ] && [ -n "$MAX_LEN" ] && [ "$MIN_LEN" -ge "$MAX_LEN" ]; then
        error_exit "min-len must be smaller than max-len"
    fi

    if [ -z "$OUTDIR" ]; then
        OUTDIR="./tcpdump_bundle_$(date +%Y%m%d_%H%M%S)"
    fi
}

list_interfaces() {
    if ! have_cmd tcpdump; then
        error_exit "tcpdump not found"
    fi
    tcpdump -D 2>&1 || true
}

tcpdump_has_any() {
    tcpdump -D 2>/dev/null | awk '{print $0}' | grep -E '(^|[[:space:]])any([[:space:]]|$|\()' >/dev/null 2>&1
}

iface_exists() {
    local iface="$1"
    [ -d "/sys/class/net/$iface" ] && return 0
    tcpdump -D 2>/dev/null | grep -E "(^|[[:space:]])${iface}([[:space:]]|$|\\()" >/dev/null 2>&1
}

first_non_loopback_iface() {
    if have_cmd ip; then
        ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {sub(/@.*/, "", $2); print $2; exit}'
        return 0
    fi
    for p in /sys/class/net/*; do
        [ -e "$p" ] || continue
        b=$(basename "$p")
        [ "$b" = "lo" ] && continue
        echo "$b"
        return 0
    done
    echo "lo"
}

resolve_interface() {
    if [ "$IFACE" = "auto" ]; then
        if tcpdump_has_any; then
            IFACE="any"
        else
            IFACE=$(first_non_loopback_iface)
        fi
    elif [ "$IFACE" = "any" ]; then
        if ! tcpdump_has_any; then
            error_exit "tcpdump does not report/support interface 'any'. Use --list-interfaces and choose a specific interface."
        fi
    else
        iface_exists "$IFACE" || error_exit "interface not found or unsupported by tcpdump: $IFACE"
    fi
}

build_filter() {
    local f=""
    local lenf=""

    if [ -n "$MIN_LEN" ]; then
        lenf="greater $MIN_LEN"
    fi
    if [ -n "$MAX_LEN" ]; then
        if [ -n "$lenf" ]; then
            lenf="($lenf) and (less $MAX_LEN)"
        else
            lenf="less $MAX_LEN"
        fi
    fi

    if [ -n "$FILTER" ] && [ -n "$lenf" ]; then
        f="($FILTER) and ($lenf)"
    elif [ -n "$FILTER" ]; then
        f="$FILTER"
    elif [ -n "$lenf" ]; then
        f="$lenf"
    else
        f=""
    fi

    printf '%s' "$f"
}

preflight() {
    mkdir -p "$OUTDIR" "$OUTDIR/pcap" "$OUTDIR/snapshots" "$OUTDIR/static" || error_exit "failed to create output directory: $OUTDIR"
    have_cmd tcpdump || error_exit "tcpdump is required but not found"
    have_cmd timeout || log "WARN: timeout command not found. Capture duration cannot be enforced cleanly."
    resolve_interface
}

save_metadata() {
    local filter_expr="$1"
    local meta="$OUTDIR/00_metadata.txt"
    {
        echo "script=$SCRIPT_NAME"
        echo "started_at_utc=$(now_utc)"
        echo "started_at_epoch=$(now_epoch)"
        echo "duration=$DURATION"
        echo "interval=$INTERVAL"
        echo "capture_secs=$CAPTURE_SECS"
        echo "interface=$IFACE"
        echo "snaplen=$SNAPLEN"
        echo "mode=$MODE"
        echo "min_len=${MIN_LEN:-none}"
        echo "max_len=${MAX_LEN:-none}"
        echo "max_file_mb=$MAX_FILE_MB"
        echo "filter=${filter_expr:-none}"
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
        echo "[tcpdump version]"
        tcpdump --version 2>&1 || true
        echo
        echo "[tcpdump interfaces]"
        tcpdump -D 2>&1 || true
        echo
        echo "[available commands]"
        for c in tcpdump timeout ip ethtool ss netstat lsof fuser journalctl dmesg tar gzip; do
            if have_cmd "$c"; then
                echo "$c=YES ($(command -v "$c"))"
            else
                echo "$c=NO"
            fi
        done
        echo
        echo "[sensitivity note]"
        echo "PCAP files may include sensitive network metadata or payload bytes depending on snaplen/filter."
    } > "$meta"
}

collect_static_context() {
    {
        echo "[ip addr]"
        ip addr show 2>/dev/null || true
        echo
        echo "[ip route]"
        ip route show 2>/dev/null || true
        echo
        echo "[ip -s link]"
        ip -s link show 2>/dev/null || true
        echo
        echo "[interface details: $IFACE]"
        if [ "$IFACE" != "any" ] && have_cmd ethtool; then
            ethtool "$IFACE" 2>&1 || true
            echo
            echo "[ethtool -S $IFACE]"
            ethtool -S "$IFACE" 2>&1 || true
        else
            echo "ethtool skipped for interface=$IFACE"
        fi
    } > "$OUTDIR/static/network_context_start.txt"
}

collect_snapshot_context() {
    local dir="$1"
    mkdir -p "$dir" || return 0

    {
        echo "[sample time]"
        now_utc
        echo
        echo "[ip -s link]"
        ip -s link show 2>/dev/null || true
        echo
        echo "[ss summary]"
        if have_cmd ss; then
            ss -s 2>&1 || true
        elif have_cmd netstat; then
            netstat -s 2>&1 || true
        else
            echo "ss/netstat unavailable"
        fi
    } > "$dir/network_snapshot.txt"

    if [ "$MODE" = "detail" ] || [ "$MODE" = "full" ]; then
        {
            echo "[ss tcp]"
            have_cmd ss && ss -tanp 2>&1 || true
            echo
            echo "[ss udp]"
            have_cmd ss && ss -uanp 2>&1 || true
            echo
            echo "[lsof network]"
            have_cmd lsof && lsof -nP -i 2>&1 || echo "lsof unavailable"
        } > "$dir/socket_owners.txt"
    fi

    if [ "$MODE" = "full" ]; then
        mkdir -p "$dir/proc_net"
        for f in dev tcp tcp6 udp udp6 raw raw6 unix netstat snmp sockstat sockstat6; do
            cat "/proc/net/$f" > "$dir/proc_net/$f.txt" 2>/dev/null || true
        done
    fi
}

run_tcpdump_once() {
    local sample_id="$1"
    local elapsed="$2"
    local filter_expr="$3"
    local pcap="$OUTDIR/pcap/sample_${sample_id}_elapsed_${elapsed}s_${IFACE}.pcap"
    local txt="$OUTDIR/snapshots/sample_${sample_id}_elapsed_${elapsed}s/tcpdump_stdout.txt"
    local dir
    dir=$(dirname "$txt")
    mkdir -p "$dir" || return 0

    {
        echo "sample_id=$sample_id"
        echo "elapsed=$elapsed"
        echo "timestamp_utc=$(now_utc)"
        echo "interface=$IFACE"
        echo "capture_secs=$CAPTURE_SECS"
        echo "snaplen=$SNAPLEN"
        echo "filter=${filter_expr:-none}"
        echo "pcap=$pcap"
    } > "$dir/sample_meta.txt"

    if have_cmd timeout; then
        if [ -n "$filter_expr" ]; then
            timeout "$CAPTURE_SECS" tcpdump -i "$IFACE" -nn -s "$SNAPLEN" -w "$pcap" "$filter_expr" > "$txt" 2>&1 || true
        else
            timeout "$CAPTURE_SECS" tcpdump -i "$IFACE" -nn -s "$SNAPLEN" -w "$pcap" > "$txt" 2>&1 || true
        fi
    else
        # Fallback: packet-count bounded capture if timeout is not available.
        if [ -n "$filter_expr" ]; then
            tcpdump -i "$IFACE" -nn -s "$SNAPLEN" -c 1000 -w "$pcap" "$filter_expr" > "$txt" 2>&1 || true
        else
            tcpdump -i "$IFACE" -nn -s "$SNAPLEN" -c 1000 -w "$pcap" > "$txt" 2>&1 || true
        fi
    fi

    if [ -f "$pcap" ]; then
        bytes=$(wc -c < "$pcap" 2>/dev/null || echo 0)
        echo "pcap_bytes=$bytes" >> "$dir/sample_meta.txt"
        max_bytes=$((MAX_FILE_MB * 1024 * 1024))
        if [ "$bytes" -gt "$max_bytes" ]; then
            echo "WARN: pcap size exceeds max-file-mb threshold: ${bytes} bytes > ${max_bytes} bytes" >> "$dir/sample_meta.txt"
        fi
    else
        echo "pcap_missing=true" >> "$dir/sample_meta.txt"
    fi
}

compress_output() {
    [ "$COMPRESS" -eq 1 ] || return 0
    have_cmd tar || { log "WARN: tar not available; skip compression"; return 0; }
    have_cmd gzip || { log "WARN: gzip not available; skip compression"; return 0; }
    parent=$(dirname "$OUTDIR")
    base=$(basename "$OUTDIR")
    archive="${OUTDIR}.tar.gz"
    (cd "$parent" && tar -czf "$archive" "$base") 2>/dev/null || log "WARN: compression failed"
}

main() {
    parse_args "$@"
    validate_args

    if [ "$LIST_ONLY" -eq 1 ]; then
        list_interfaces
        exit 0
    fi

    preflight
    filter_expr=$(build_filter)
    START_EPOCH=$(now_epoch)
    end_epoch=$((START_EPOCH + DURATION))

    save_metadata "$filter_expr"
    collect_static_context

    log "INFO: output directory: $OUTDIR"
    log "INFO: interface=$IFACE duration=$DURATION interval=$INTERVAL capture_secs=$CAPTURE_SECS snaplen=$SNAPLEN"
    [ -n "$filter_expr" ] && log "INFO: filter=$filter_expr"

    sample_id=0
    while :; do
        now=$(now_epoch)
        [ "$now" -ge "$end_epoch" ] && break
        elapsed=$((now - START_EPOCH))
        sample_id=$((sample_id + 1))
        snapdir="$OUTDIR/snapshots/sample_${sample_id}_elapsed_${elapsed}s"
        collect_snapshot_context "$snapdir"
        run_tcpdump_once "$sample_id" "$elapsed" "$filter_expr"
        sleep "$INTERVAL"
    done

    {
        echo "completed_at_utc=$(now_utc)"
        echo "completed_at_epoch=$(now_epoch)"
        echo "samples_collected=$sample_id"
    } > "$OUTDIR/99_collection_end.txt"

    {
        echo "[ip -s link end]"
        ip -s link show 2>/dev/null || true
    } > "$OUTDIR/static/network_context_end.txt"

    compress_output
    log "INFO: completed: $OUTDIR"
}

main "$@"
