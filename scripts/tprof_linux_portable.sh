#!/usr/bin/env bash
# tprof_linux_portable.sh
# Linux-native profiler shim
# - perf available: perf record/report
# - otherwise fallback: pidstat/top/ps/vmstat

set -euo pipefail
IFS=$' \t\n'
umask 077
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export LANG=C
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage:
  tprof_linux_portable.sh [-i INTERVAL] [-o OUT_DIR] [-p "CMD ARGS"] TOTAL_SECONDS

Options:
  -i INTERVAL   Sampling interval in seconds (default: 5)
  -o OUT_DIR    Output directory (default: current directory)
  -p PROGRAM    Optional command to run during profiling
  -h            Show help

Arguments:
  TOTAL_SECONDS Total profiling duration in seconds (minimum 10)
EOF
}

err() {
  echo "ERROR: $*" >&2
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Required command not found: $1"
    exit 1
  }
}

uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

safe_hostname() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || uname -n 2>/dev/null || echo "unknown-host"
}

read_os_info() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s|%s|%s\n' "${NAME:-unknown}" "${VERSION_ID:-unknown}" "${PRETTY_NAME:-unknown}"
  else
    printf 'unknown|unknown|unknown\n'
  fi
}

OUT_DIR='.'
INTERVAL=5
PROGRAM=''

while getopts ':i:o:p:h' opt; do
  case "$opt" in
    i) INTERVAL="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    p) PROGRAM="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) err "Option -$OPTARG requires a value"; exit 1 ;;
    \?) err "Unknown option -$OPTARG"; exit 1 ;;
  esac
done

shift $((OPTIND - 1))

TOTAL="${1:-}"
[[ -n "$TOTAL" ]] || { usage; exit 1; }
uint "$TOTAL" || { err "TOTAL_SECONDS must be a positive integer"; exit 1; }
(( TOTAL >= 10 )) || { err "Minimum profiling duration is 10 seconds"; exit 1; }

uint "$INTERVAL" || { err "INTERVAL must be a positive integer"; exit 1; }
(( INTERVAL > 0 )) || { err "INTERVAL must be greater than 0"; exit 1; }

need awk
need sed
need grep
need date
need uname
need mktemp
need ps
need top
need vmstat

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

DATA_DIR="$OUT_DIR/tprof_data"
mkdir -p "$DATA_DIR"

TMP_DIR="$(mktemp -d -p "${TMPDIR:-/tmp}" tprof_portable.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'jobs -p | xargs -r kill >/dev/null 2>&1 || true; exit 130' INT TERM HUP

HOST="$(safe_hostname)"
START_TIME="$(date '+%F %T %Z')"
OS_INFO="$(read_os_info)"
OS_NAME="${OS_INFO%%|*}"
REST="${OS_INFO#*|}"
OS_VER="${REST%%|*}"
OS_PRETTY="${REST#*|}"
KERNEL="$(uname -r)"
ARCH="$(uname -m)"

SUMFILE="$OUT_DIR/tprof.sum"
METAFILE="$OUT_DIR/tprof.meta"

PIDSTATFILE="$DATA_DIR/pidstat.out"
TOPFILE="$DATA_DIR/top.out"
PSFILE="$DATA_DIR/ps.out"
VMSTATFILE="$DATA_DIR/vmstat.out"
PROGRAM_LOG="$DATA_DIR/program.log"

PERF_DATA="$DATA_DIR/perf.data"
PERF_REPORT="$DATA_DIR/perf.report.txt"
PERF_STAT="$DATA_DIR/perf.stat.txt"
PERF_RECORD_LOG="$DATA_DIR/perf.record.log"

PS_AWK="$TMP_DIR/ps_summary.awk"

{
  echo "script=tprof_linux_portable.sh"
  echo "hostname=$HOST"
  echo "os_name=$OS_NAME"
  echo "os_version=$OS_VER"
  echo "os_pretty=$OS_PRETTY"
  echo "kernel=$KERNEL"
  echo "arch=$ARCH"
  echo "start_time=$START_TIME"
  echo "interval=$INTERVAL"
  echo "total_seconds=$TOTAL"
  echo "program=${PROGRAM:-none}"
} > "$METAFILE"

printf "\n T P R O F _ L I N U X _ P O R T A B L E\n\n" > "$SUMFILE"
printf "Hostname: %s\n" "$HOST" >> "$SUMFILE"
printf "OS      : %s\n" "$OS_PRETTY" >> "$SUMFILE"
printf "Kernel  : %s\n" "$KERNEL" >> "$SUMFILE"
printf "Arch    : %s\n" "$ARCH" >> "$SUMFILE"
printf "Start   : %s\n" "$START_TIME" >> "$SUMFILE"
printf "Duration: %s sec\n" "$TOTAL" >> "$SUMFILE"
printf "Interval: %s sec\n" "$INTERVAL" >> "$SUMFILE"
printf "Program : %s\n" "${PROGRAM:-none}" >> "$SUMFILE"

PROGRAM_PID=''

if [[ -n "$PROGRAM" ]]; then
  echo "TPROF: Launching target command: $PROGRAM"
  bash -c "$PROGRAM" > "$PROGRAM_LOG" 2>&1 &
  PROGRAM_PID=$!
  echo "program_pid=$PROGRAM_PID" >> "$METAFILE"
fi

collect_pidstat() {
  if command -v pidstat >/dev/null 2>&1; then
    pidstat -u -r -d -h -p ALL "$INTERVAL" "$(( TOTAL / INTERVAL + 1 ))" > "$PIDSTATFILE" 2>&1 || true
  else
    echo "pidstat not available" > "$PIDSTATFILE"
  fi
}

collect_top() {
  top -b -d "$INTERVAL" -n "$(( TOTAL / INTERVAL + 1 ))" > "$TOPFILE" 2>&1 || true
}

collect_ps_loop() {
  local iterations
  iterations=$(( TOTAL / INTERVAL ))
  (( iterations < 1 )) && iterations=1

  : > "$PSFILE"

  for ((i = 1; i <= iterations; i++)); do
    echo "===== ps sample $i =====" >> "$PSFILE"
    date '+%F %T %Z' >> "$PSFILE"
    ps -eo pid,ppid,comm,%cpu,%mem,stat,etimes,time --sort=-%cpu | head -n 40 >> "$PSFILE"
    echo >> "$PSFILE"
    (( i < iterations )) && sleep "$INTERVAL"
  done
}

collect_vmstat() {
  vmstat -w -t "$INTERVAL" "$(( TOTAL / INTERVAL + 1 ))" > "$VMSTATFILE" 2>&1 \
    || vmstat "$INTERVAL" "$(( TOTAL / INTERVAL + 1 ))" > "$VMSTATFILE" 2>&1 \
    || true
}

collect_perf() {
  command -v perf >/dev/null 2>&1 || return 1

  if [[ -n "$PROGRAM_PID" ]]; then
    perf record -o "$PERF_DATA" -F 99 -g -p "$PROGRAM_PID" -- sleep "$TOTAL" > "$PERF_RECORD_LOG" 2>&1 || return 1
    perf stat -p "$PROGRAM_PID" sleep "$TOTAL" > "$PERF_STAT" 2>&1 || true
  else
    perf record -o "$PERF_DATA" -F 99 -g -a -- sleep "$TOTAL" > "$PERF_RECORD_LOG" 2>&1 || return 1
    perf stat -a sleep "$TOTAL" > "$PERF_STAT" 2>&1 || true
  fi

  perf report --stdio -i "$PERF_DATA" > "$PERF_REPORT" 2>&1 || true
  return 0
}

cat > "$PS_AWK" <<'AWK'
/^[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {
  c = $3
  cpu = $4 + 0
  n[c]++
  s[c] += cpu
  if (cpu > m[c]) {
    m[c] = cpu
  }
}
END {
  for (c in n) {
    printf "%8.2f %8.2f %6d %s\n", s[c] / n[c], m[c], n[c], c
  }
}
AWK

echo "TPROF: Collecting Linux-native profiling artifacts...."

collect_pidstat & P1=$!
collect_top & P2=$!
collect_vmstat & P3=$!
collect_ps_loop & P4=$!

PERF_OK=0
if collect_perf; then
  PERF_OK=1
fi

wait "$P1" "$P2" "$P3" "$P4" || true

if [[ -n "$PROGRAM_PID" ]]; then
  wait "$PROGRAM_PID" || true
fi

END_TIME="$(date '+%F %T %Z')"
echo "end_time=$END_TIME" >> "$METAFILE"

echo >> "$SUMFILE"
echo "End: $END_TIME" >> "$SUMFILE"

echo >> "$SUMFILE"
echo "Method summary" >> "$SUMFILE"
echo "==============" >> "$SUMFILE"
if (( PERF_OK == 1 )); then
  echo "Primary profiler: perf" >> "$SUMFILE"
else
  echo "Primary profiler: fallback (pidstat/top/ps/vmstat)" >> "$SUMFILE"
fi
echo "Raw data directory: $DATA_DIR" >> "$SUMFILE"

echo >> "$SUMFILE"
echo "Top CPU consumers (avg/max over samples)" >> "$SUMFILE"
echo "========================================" >> "$SUMFILE"
awk -f "$PS_AWK" "$PSFILE" | sort -rn | head -n 20 >> "$SUMFILE" || true

echo >> "$SUMFILE"
echo "pidstat excerpt" >> "$SUMFILE"
echo "==============" >> "$SUMFILE"
if [[ -s "$PIDSTATFILE" ]]; then
  tail -n 80 "$PIDSTATFILE" >> "$SUMFILE"
else
  echo "pidstat output not available" >> "$SUMFILE"
fi

echo >> "$SUMFILE"
echo "vmstat tail" >> "$SUMFILE"
echo "===========" >> "$SUMFILE"
tail -n 40 "$VMSTATFILE" >> "$SUMFILE" 2>/dev/null || true

if (( PERF_OK == 1 )); then
  echo >> "$SUMFILE"
  echo "perf report head" >> "$SUMFILE"
  echo "================" >> "$SUMFILE"
  head -n 80 "$PERF_REPORT" >> "$SUMFILE" 2>/dev/null || true

  echo >> "$SUMFILE"
  echo "perf stat" >> "$SUMFILE"
  echo "=========" >> "$SUMFILE"
  cat "$PERF_STAT" >> "$SUMFILE" 2>/dev/null || true
fi

echo "TPROF: Summary: $SUMFILE"
echo "TPROF: Metadata: $METAFILE"
echo "TPROF: Raw data directory: $DATA_DIR"
