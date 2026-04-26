#!/usr/bin/env bash
# tprof_linux_portable.sh
# Linux-native profiler shim (perf if available; else pidstat/top/ps/vmstat)
set -euo pipefail
IFS=$' 	
'
umask 077
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export LANG=C LC_ALL=C

usage(){ echo "Usage: $0 [-i INTERVAL] [-o OUT_DIR] [-p 'CMD ARGS'] TOTAL_SECONDS"; }
err(){ echo "ERROR: $*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; exit 1; }; }
uint(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }

OUT_DIR='.'; INTERVAL=5; PROGRAM=''
while getopts ':i:o:p:h' o; do
  case "$o" in
    i) INTERVAL="$OPTARG";;
    o) OUT_DIR="$OPTARG";;
    p) PROGRAM="$OPTARG";;
    h) usage; exit 0;;
    :) err "-$OPTARG requires a value"; exit 1;;
    \?) err "Unknown option -$OPTARG"; exit 1;;
  esac
done
shift $((OPTIND-1))
TOTAL="${1:-}"; [[ -n "$TOTAL" ]] || { usage; exit 1; }
uint "$TOTAL" || { err "TOTAL_SECONDS must be integer"; exit 1; }
(( TOTAL >= 10 )) || { err "Minimum profiling duration is 10 seconds"; exit 1; }
uint "$INTERVAL" || { err "INTERVAL must be integer"; exit 1; }
(( INTERVAL > 0 )) || { err "INTERVAL must be > 0"; exit 1; }

need awk; need sed; need grep; need date; need uname; need mktemp; need hostname; need ps; need top; need vmstat
mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
DATA_DIR="$OUT_DIR/tprof_data"; mkdir -p "$DATA_DIR"
TMP="$(mktemp -d -p "${TMPDIR:-/tmp}" tprof_portable.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
trap 'jobs -p | xargs -r kill >/dev/null 2>&1 || true; exit 130' INT TERM HUP

SUMFILE="$OUT_DIR/tprof.sum"; METAFILE="$OUT_DIR/tprof.meta"
PIDSTAT="$DATA_DIR/pidstat.out"; TOPF="$DATA_DIR/top.out"; PSF="$DATA_DIR/ps.out"; VMF="$DATA_DIR/vmstat.out"
PERF_DATA="$DATA_DIR/perf.data"; PERF_REP="$DATA_DIR/perf.report.txt"; PERF_STAT="$DATA_DIR/perf.stat.txt"; PERF_LOG="$DATA_DIR/perf.record.log"
PROG_LOG="$DATA_DIR/program.log"; PROGRAM_PID=""

{
  echo "script=tprof_linux_portable.sh";
  echo "hostname=$(hostname -s 2>/dev/null || hostname || true)";
  echo "kernel=$(uname -r)";
  echo "arch=$(uname -m)";
  echo "start_time=$(date '+%F %T %Z')";
  echo "interval=$INTERVAL";
  echo "total_seconds=$TOTAL";
  echo "program=${PROGRAM:-none}";
} > "$METAFILE"

printf "
 T P R O F _ L I N U X _ P O R T A B L E

" > "$SUMFILE"

if [[ -n "$PROGRAM" ]]; then
  bash -c "$PROGRAM" > "$PROG_LOG" 2>&1 &
  PROGRAM_PID=$!
  echo "program_pid=$PROGRAM_PID" >> "$METAFILE"
fi

collect_pidstat(){
  if command -v pidstat >/dev/null 2>&1; then
    pidstat -u -r -d -h -p ALL "$INTERVAL" "$(( TOTAL/INTERVAL + 1 ))" > "$PIDSTAT" 2>&1 || true
  else
    echo "pidstat not available" > "$PIDSTAT"
  fi
}
collect_top(){ top -b -d "$INTERVAL" -n "$(( TOTAL/INTERVAL + 1 ))" > "$TOPF" 2>&1 || true; }
collect_ps(){
  it=$(( TOTAL/INTERVAL )); (( it<1 )) && it=1
  : > "$PSF"
  for ((i=1;i<=it;i++)); do
    echo "
===== ps sample $i =====" >> "$PSF"
    date '+%F %T %Z' >> "$PSF"
    ps -eo pid,ppid,comm,%cpu,%mem,stat,etimes,time --sort=-%cpu | head -n 40 >> "$PSF"
    (( i<it )) && sleep "$INTERVAL"
  done
}
collect_vm(){ vmstat -w -t "$INTERVAL" "$(( TOTAL/INTERVAL + 1 ))" > "$VMF" 2>&1 || vmstat "$INTERVAL" "$(( TOTAL/INTERVAL + 1 ))" > "$VMF" 2>&1 || true; }
collect_perf(){
  command -v perf >/dev/null 2>&1 || return 1
  if [[ -n "$PROGRAM_PID" ]]; then
    perf record -o "$PERF_DATA" -F 99 -g -p "$PROGRAM_PID" -- sleep "$TOTAL" > "$PERF_LOG" 2>&1 || return 1
    perf stat -p "$PROGRAM_PID" sleep "$TOTAL" > "$PERF_STAT" 2>&1 || true
  else
    perf record -o "$PERF_DATA" -F 99 -g -a -- sleep "$TOTAL" > "$PERF_LOG" 2>&1 || return 1
    perf stat -a sleep "$TOTAL" > "$PERF_STAT" 2>&1 || true
  fi
  perf report --stdio -i "$PERF_DATA" > "$PERF_REP" 2>&1 || true
  return 0
}

collect_pidstat & P1=$!
collect_top & P2=$!
collect_vm & P3=$!
collect_ps & P4=$!
PERF_OK=0
collect_perf && PERF_OK=1 || true
wait "$P1" "$P2" "$P3" "$P4" || true
[[ -n "$PROGRAM_PID" ]] && wait "$PROGRAM_PID" || true

echo "End: $(date '+%F %T %Z')" >> "$SUMFILE"
if (( PERF_OK )); then echo "Method: perf" >> "$SUMFILE"; else echo "Method: fallback (pidstat/top/ps/vmstat)" >> "$SUMFILE"; fi

echo "
Top CPU consumers (avg/max over samples)" >> "$SUMFILE"
awk '/^[0-9]+[[:space:]]+[0-9]+[[:space:]]+/ {c=$3;cpu=$4+0;n[c]++;s[c]+=cpu;if(cpu>m[c])m[c]=cpu} END{for(c in n) printf "%8.2f %8.2f %6d %s
", s[c]/n[c], m[c], n[c], c}' "$PSF" | sort -rn | head -n 20 >> "$SUMFILE" || true

echo "
vmstat tail" >> "$SUMFILE"; tail -n 40 "$VMF" >> "$SUMFILE" 2>/dev/null || true
if (( PERF_OK )); then echo "
perf report head" >> "$SUMFILE"; head -n 80 "$PERF_REP" >> "$SUMFILE" 2>/dev/null || true; fi

echo "TPROF: Summary: $SUMFILE"
