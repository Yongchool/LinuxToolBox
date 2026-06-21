#!/usr/bin/env bash

# collect_socket_perf_bundle.sh
#
# Portable socket/network evidence collector
#
# Goals:
#   - prefer ss
#   - fallback to fuser / lsof / netstat / raw /proc
#   - support network namespace collection via nsenter
#   - keep default collection lightweight
#   - allow optional packet capture
#
# Suggested targets:
#   - Ubuntu 22.04 / 24.04
#   - Debian 11 / 12
#   - Oracle Linux
#   - RHEL 8 / 9
#   - SLES 12 SP5 / 15 SP6
#
# Requirements:
#   bash, date, uname, mkdir, cat, awk, sed, grep, sleep
#
# Optional tools:
#   ss, fuser, lsof, netstat, nsenter, tcpdump, perf, bpftrace, pcp-ss
#
# Example:
#   ./collect_socket_perf_bundle.sh -d 300 -i 10 -o ./socket_bundle
#   ./collect_socket_perf_bundle.sh -d 120 -i 2 -p 22,443,8443 -o ./socket_bundle
#   ./collect_socket_perf_bundle.sh -d 180 -i 5 -n 1234 -o ./socket_bundle
#   ./collect_socket_perf_bundle.sh -d 60 -i 2 -I eth0 -C 15 -o ./socket_bundle

set -euo pipefail
IFS=$'\n\t'

DURATION=300
INTERVAL=10
LSOF_EVERY=60
OUTDIR=""
PORTS=""
NETNS_PID=""
TCPDUMP_IFACE=""
TCPDUMP_SECS=0
ENABLE_TCPDUMP=0
ENABLE_EBPF=0
ENABLE_LSOF=1

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat <<'EOF'
Usage:
  collect_socket_perf_bundle.sh [options]

Options:
  -d SEC    Total collection duration in seconds (default: 300)
  -i SEC    Collection interval in seconds (default: 10)
  -l SEC    lsof cadence in seconds (default: 60)
  -o DIR    Output directory (default: ./socket_bundle_YYYYmmdd_HHMMSS)
  -p LIST   Comma-separated port list for fuser quick checks (example: 22,80,443)
  -n PID    Enter target PID's network namespace using nsenter -t PID -n
  -I IFACE  Enable tcpdump on interface IFACE
  -C SEC    tcpdump capture duration per run (default: disabled)
  -L        Disable lsof collection
  -h        Show this help

Notes:
  - ss is the preferred primary backend
  - fuser is used for quick PID lookup for selected ports
  - lsof is broader but heavier, so it is sampled less frequently
  - netstat is used as legacy fallback
  - /proc raw files are always collected as last-resort evidence
  - tcpdump is optional and disabled by default
EOF
}

log() {
  printf '%s\n' "$*" >&2
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

error_exit() {
  log "ERROR: $*"
  exit 1
}

safe_mkdir() {
  mkdir -p "$1" || error_exit "failed to create directory: $1"
}

run_in_ns() {
  if [[ -n "$NETNS_PID" ]]; then
    if ! have_cmd nsenter; then
      error_exit "nsenter not available but -n PID was specified"
    fi
    nsenter -t "$NETNS_PID" -n -- "$@"
  else
    "$@"
  fi
}

run_in_ns_sh() {
  local cmd="$1"
  if [[ -n "$NETNS_PID" ]]; then
    if ! have_cmd nsenter; then
      error_exit "nsenter not available but -n PID was specified"
    fi
    nsenter -t "$NETNS_PID" -n -- bash -lc "$cmd"
  else
    bash -lc "$cmd"
  fi
}

timestamp_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

epoch_now() {
  date +%s
}

sanitize_name() {
  echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

collect_metadata() {
  local meta="$OUTDIR/00_metadata.txt"
  {
    echo "script=$SCRIPT_NAME"
    echo "collected_at_utc=$(timestamp_utc)"
    echo "collected_at_epoch=$(epoch_now)"
    echo "hostname=$(hostname 2>/dev/null || uname -n)"
    echo "kernel=$(uname -r)"
    echo "kernel_full=$(uname -a)"
    echo "arch=$(uname -m)"
    echo "duration=$DURATION"
    echo "interval=$INTERVAL"
    echo "lsof_every=$LSOF_EVERY"
    echo "ports=${PORTS:-none}"
    echo "netns_pid=${NETNS_PID:-none}"
    echo "tcpdump_iface=${TCPDUMP_IFACE:-none}"
    echo "tcpdump_secs=$TCPDUMP_SECS"
    echo "enable_lsof=$ENABLE_LSOF"
    echo "enable_tcpdump=$ENABLE_TCPDUMP"
    echo "enable_ebpf=$ENABLE_EBPF"
    echo
    echo "[os-release]"
    if [[ -r /etc/os-release ]]; then
      cat /etc/os-release
    else
      echo "not available"
    fi
    echo
    echo "[command-availability]"
    for c in ss fuser lsof netstat nsenter tcpdump bpftrace perf pcp-ss awk sed grep cat ls ip; do
      if have_cmd "$c"; then
        echo "$c=YES ($(command -v "$c"))"
      else
        echo "$c=NO"
      fi
    done
    echo
    echo "[namespace-info]"
    if [[ -n "$NETNS_PID" ]]; then
      echo "target_pid=$NETNS_PID"
      if [[ -e "/proc/$NETNS_PID/ns/net" ]]; then
        ls -l "/proc/$NETNS_PID/ns/net" 2>/dev/null || true
      else
        echo "/proc/$NETNS_PID/ns/net not found"
      fi
    else
      echo "host network namespace"
      [[ -e /proc/self/ns/net ]] && ls -l /proc/self/ns/net 2>/dev/null || true
    fi
  } > "$meta"
}

collect_static_network_context() {
  local out="$OUTDIR/01_static_context"
  safe_mkdir "$out"

  run_in_ns_sh 'ip addr show 2>/dev/null || true' > "$out/ip_addr.txt" 2>&1 || true
  run_in_ns_sh 'ip route show 2>/dev/null || true' > "$out/ip_route.txt" 2>&1 || true
  run_in_ns_sh 'ip -s link show 2>/dev/null || true' > "$out/ip_link_stats.txt" 2>&1 || true

  if have_cmd netstat; then
    run_in_ns netstat -rn > "$out/netstat_rn.txt" 2>&1 || true
    run_in_ns netstat -i > "$out/netstat_i.txt" 2>&1 || true
  fi

  if [[ -n "$NETNS_PID" ]] && [[ -d "/proc/$NETNS_PID" ]]; then
    {
      echo "[/proc/$NETNS_PID/status]"
      cat "/proc/$NETNS_PID/status" 2>/dev/null || true
      echo
      echo "[/proc/$NETNS_PID/limits]"
      cat "/proc/$NETNS_PID/limits" 2>/dev/null || true
      echo
      echo "[/proc/$NETNS_PID/cgroup]"
      cat "/proc/$NETNS_PID/cgroup" 2>/dev/null || true
    } > "$out/target_pid_context.txt"
  fi
}

collect_proc_raw() {
  local tickdir="$1"
  local procdir="$tickdir/proc_net_raw"
  safe_mkdir "$procdir"

  for f in tcp tcp6 udp udp6 raw raw6 unix dev netstat snmp sockstat sockstat6; do
    run_in_ns_sh "cat /proc/net/$f 2>/dev/null || true" > "$procdir/$f.txt" 2>&1 || true
  done

  if [[ -n "$NETNS_PID" ]] && [[ -d "/proc/$NETNS_PID/net" ]]; then
    safe_mkdir "$tickdir/proc_target_pid_net"
    for f in tcp tcp6 udp udp6 raw raw6 unix dev netstat snmp sockstat sockstat6; do
      cat "/proc/$NETNS_PID/net/$f" > "$tickdir/proc_target_pid_net/$f.txt" 2>/dev/null || true
    done
  fi
}

collect_ss() {
  local tickdir="$1"

  if have_cmd ss; then
    run_in_ns ss -s > "$tickdir/ss_summary.txt" 2>&1 || true
    run_in_ns ss -tanp > "$tickdir/ss_tcp_all.txt" 2>&1 || true
    run_in_ns ss -uanp > "$tickdir/ss_udp_all.txt" 2>&1 || true
    run_in_ns ss -xap > "$tickdir/ss_unix_all.txt" 2>&1 || true
    run_in_ns ss -ltnp > "$tickdir/ss_tcp_listen.txt" 2>&1 || true
    run_in_ns ss -lunp > "$tickdir/ss_udp_listen.txt" 2>&1 || true
  elif have_cmd netstat; then
    run_in_ns netstat -s > "$tickdir/netstat_s.txt" 2>&1 || true
    run_in_ns netstat -anp > "$tickdir/netstat_anp.txt" 2>&1 || true
  else
    echo "Neither ss nor netstat available" > "$tickdir/socket_backend_unavailable.txt"
  fi
}

collect_fuser_ports() {
  local tickdir="$1"

  [[ -n "$PORTS" ]] || return 0
  have_cmd fuser || return 0

  local out="$tickdir/fuser_ports.txt"
  : > "$out"

  oldIFS=$IFS
  IFS=','

  for port in $PORTS; do
    port="$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$port" ]] || continue

    {
      echo "### port=$port protocol=tcp"
      run_in_ns fuser -n tcp "$port" 2>&1 || true
      echo
      echo "### port=$port protocol=udp"
      run_in_ns fuser -n udp "$port" 2>&1 || true
      echo
    } >> "$out"
  done

  IFS=$oldIFS
}

collect_lsof() {
  local tickdir="$1"

  [[ "$ENABLE_LSOF" -eq 1 ]] || return 0
  have_cmd lsof || return 0

  if [[ -n "$NETNS_PID" ]]; then
    # lsof is process/file oriented; with namespace collection we still keep a broad owner view from host.
    lsof -nP -i > "$tickdir/lsof_i.txt" 2>&1 || true
    lsof -nP > "$tickdir/lsof_all.txt" 2>&1 || true
  else
    lsof -nP -i > "$tickdir/lsof_i.txt" 2>&1 || true
    lsof -nP > "$tickdir/lsof_all.txt" 2>&1 || true
  fi
}

collect_netstat_fallback() {
  local tickdir="$1"
  have_cmd netstat || return 0

  run_in_ns netstat -s > "$tickdir/netstat_stats.txt" 2>&1 || true
  run_in_ns netstat -anp > "$tickdir/netstat_anp.txt" 2>&1 || true
}

collect_tcpdump() {
  local tickdir="$1"

  [[ "$ENABLE_TCPDUMP" -eq 1 ]] || return 0
  [[ -n "$TCPDUMP_IFACE" ]] || return 0
  have_cmd tcpdump || return 0
  have_cmd timeout || return 0

  local pcap="$tickdir/tcpdump_${TCPDUMP_IFACE}.pcap"
  timeout "$TCPDUMP_SECS" tcpdump -i "$TCPDUMP_IFACE" -nn -s 128 -w "$pcap" > "$tickdir/tcpdump_stdout.txt" 2>&1 || true
}

collect_optional_ebpf_note() {
  local tickdir="$1"

  if [[ "$ENABLE_EBPF" -eq 1 ]]; then
    {
      echo "eBPF requested but not enabled by default in this script."
      echo "Use bpftrace/bcc separately for short-lived connection flow tracing."
      echo "Reason: higher compatibility risk across old/minimal kernels and distributions."
    } > "$tickdir/ebpf_note.txt"
  fi
}

sample_once() {
  local sample_id="$1"
  local tick_epoch="$2"
  local tickdir="$OUTDIR/samples/sample_${sample_id}"

  safe_mkdir "$tickdir"

  {
    echo "sample_id=$sample_id"
    echo "sample_epoch=$tick_epoch"
    echo "sample_utc=$(date -u -d "@$tick_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$tickdir/sample_meta.txt"

  collect_ss "$tickdir"
  collect_fuser_ports "$tickdir"
  collect_proc_raw "$tickdir"
  collect_netstat_fallback "$tickdir"
  collect_tcpdump "$tickdir"
  collect_optional_ebpf_note "$tickdir"

  if (( (tick_epoch - START_EPOCH) % LSOF_EVERY == 0 )); then
    collect_lsof "$tickdir"
  fi
}

###############################################################################
# argument parsing
###############################################################################

while getopts ":d:i:l:o:p:n:I:C:Lh" opt; do
  case "$opt" in
    d) DURATION="$OPTARG" ;;
    i) INTERVAL="$OPTARG" ;;
    l) LSOF_EVERY="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    p) PORTS="$OPTARG" ;;
    n) NETNS_PID="$OPTARG" ;;
    I) TCPDUMP_IFACE="$OPTARG"; ENABLE_TCPDUMP=1 ;;
    C) TCPDUMP_SECS="$OPTARG"; ENABLE_TCPDUMP=1 ;;
    L) ENABLE_LSOF=0 ;;
    h) usage; exit 0 ;;
    :) error_exit "option -$OPTARG requires a value" ;;
    \?) error_exit "unknown option: -$OPTARG" ;;
  esac
done

for n in "$DURATION" "$INTERVAL" "$LSOF_EVERY"; do
  [[ "$n" =~ ^[0-9]+$ ]] || error_exit "duration/interval/lsof cadence must be positive integers"
done

(( DURATION > 0 )) || error_exit "duration must be > 0"
(( INTERVAL > 0 )) || error_exit "interval must be > 0"
(( LSOF_EVERY > 0 )) || error_exit "lsof cadence must be > 0"

if [[ -n "$NETNS_PID" ]]; then
  [[ "$NETNS_PID" =~ ^[0-9]+$ ]] || error_exit "namespace PID must be numeric"
  [[ -d "/proc/$NETNS_PID" ]] || error_exit "PID does not exist: $NETNS_PID"
fi

if [[ -z "$OUTDIR" ]]; then
  OUTDIR="./socket_bundle_$(date +%Y%m%d_%H%M%S)"
fi

safe_mkdir "$OUTDIR"
safe_mkdir "$OUTDIR/samples"

START_EPOCH="$(epoch_now)"
END_EPOCH=$((START_EPOCH + DURATION))

collect_metadata
collect_static_network_context

log "INFO: output directory = $OUTDIR"
log "INFO: duration=$DURATION interval=$INTERVAL lsof_every=$LSOF_EVERY"

sample_id=0
while :; do
  now="$(epoch_now)"
  (( now >= END_EPOCH )) && break

  sample_id=$((sample_id + 1))
  sample_once "$sample_id" "$now"

  sleep "$INTERVAL"
done

# Final marker
{
  echo "completed_at_utc=$(timestamp_utc)"
  echo "completed_at_epoch=$(epoch_now)"
  echo "samples_collected=$sample_id"
} > "$OUTDIR/99_collection_end.txt"

log "INFO: collection completed: $OUTDIR"
exit 0
