#!/usr/bin/env bash
# netstat_linux_portable.sh
# Portable Linux network collector (ss/ip/proc/ethtool)
set -euo pipefail
IFS=$' 	
'
umask 077
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export LANG=C LC_ALL=C

usage(){ echo "Usage: $0 [-d DEV]... [-i INTERVAL] [-o OUT_DIR] [TOTAL_SECONDS]"; }
err(){ echo "ERROR: $*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; exit 1; }; }
uint(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }

OUT_DIR='.'; INTERVAL=''; declare -a USER_DEVS=()
while getopts ':d:i:o:h' o; do
  case "$o" in
    d) USER_DEVS+=("$OPTARG");;
    i) INTERVAL="$OPTARG";;
    o) OUT_DIR="$OPTARG";;
    h) usage; exit 0;;
    :) err "-$OPTARG requires a value"; exit 1;;
    \?) err "Unknown option -$OPTARG"; exit 1;;
  esac
done
shift $((OPTIND-1))
TOTAL="${1:-}"

if [[ -n "$TOTAL" ]]; then uint "$TOTAL" || { err "TOTAL_SECONDS must be integer"; exit 1; }; fi
if [[ -n "$INTERVAL" ]]; then uint "$INTERVAL" || { err "INTERVAL must be integer"; exit 1; }
elif [[ -n "${PERFPMR_MONITOR_INTVLTIME:-}" ]]; then INTERVAL="$PERFPMR_MONITOR_INTVLTIME"; uint "$INTERVAL" || { err "PERFPMR_MONITOR_INTVLTIME must be integer"; exit 1; }
else if [[ -z "$TOTAL" || "$TOTAL" -lt 601 ]]; then INTERVAL=10; else INTERVAL=60; fi
fi
(( INTERVAL > 0 )) || { err "INTERVAL must be > 0"; exit 1; }

need awk; need date; need cat; need grep; need sed; need mktemp; need uname; need hostname; need ip
mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
TMP="$(mktemp -d -p "${TMPDIR:-/tmp}" netstat_portable.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

build_devs(){
  if (( ${#USER_DEVS[@]} )); then printf '%s
' "${USER_DEVS[@]}"; return; fi
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -Ev '^(lo)$' || true
}
collect_sock(){
  echo "
ss -s"; echo "------";
  if command -v ss >/dev/null 2>&1; then ss -s 2>/dev/null || true; else echo "ss not available"; fi
  echo "
ss -tan state summary"; echo "---------------------";
  command -v ss >/dev/null 2>&1 && ss -tan 2>/dev/null | awk 'NR>1{s[$1]++} END{for(k in s) print k,s[k]}' | sort || true
}
collect_if(){
  local tag="$1" dev
  echo "
===== Interface snapshot ($tag) ====="; echo "Time: $(date '+%F %T %Z')"
  echo "
/proc/net/dev"; echo "-------------"; cat /proc/net/dev 2>/dev/null || true
  echo "
 ip -s link"; echo "----------"; ip -s link 2>/dev/null || true
  for dev in "${DEVS[@]}"; do
    echo "
[$dev] ethtool"; echo "---------";
    command -v ethtool >/dev/null 2>&1 && ethtool "$dev" 2>/dev/null || true
    command -v ethtool >/dev/null 2>&1 && ethtool -S "$dev" 2>/dev/null || true
  done
}

mapfile -t DEVS < <(build_devs)
OUTFILE="$OUT_DIR/netstat.int"; SUMFILE="$OUT_DIR/netstat.sum"; METAFILE="$OUT_DIR/netstat.meta"
{
  echo "script=netstat_linux_portable.sh";
  echo "hostname=$(hostname -s 2>/dev/null || hostname || true)";
  echo "kernel=$(uname -r)";
  echo "arch=$(uname -m)";
  echo "start_time=$(date '+%F %T %Z')";
  echo "interval=$INTERVAL";
  echo "total_seconds=${TOTAL:-0}";
  echo "devices=${DEVS[*]:-none}";
} > "$METAFILE"

printf "
 N E T S T A T _ L I N U X _ P O R T A B L E

" > "$OUTFILE"
collect_sock >> "$OUTFILE"
collect_if before >> "$OUTFILE"

if [[ -n "$TOTAL" && "$TOTAL" -gt 0 ]]; then
  it=$(( TOTAL / INTERVAL )); (( it<1 )) && it=1
  for ((n=1;n<=it;n++)); do
    echo "
===== Interval sample $n/$it =====" >> "$OUTFILE"
    echo "Sample time: $(date '+%F %T %Z')" >> "$OUTFILE"
    collect_sock >> "$OUTFILE"
    echo "
/proc/net/dev (sample)" >> "$OUTFILE"; cat /proc/net/dev >> "$OUTFILE" 2>/dev/null || true
    (( n<it )) && sleep "$INTERVAL"
  done
  collect_if after >> "$OUTFILE"
fi

awk '
/^[A-Z0-9_-]+[[:space:]]+[0-9]+$/ { st[$1]+=$2 }
/^ *[[:alnum:]_.:-]+: *[0-9]+ *[0-9]+/ { gsub(":","",$1); rx[$1]+=$2; tx[$1]+=$10 }
END{
  print "Socket state counts"; print "-------------------";
  for(k in st) print k,st[k];
  print "
Interface RX/TX bytes roll-up"; print "------------------------------";
  for(d in rx) print d, "rx_bytes="rx[d], "tx_bytes="tx[d]
}
' "$OUTFILE" > "$SUMFILE"

echo "NETSTAT: Interval report: $OUTFILE"
echo "NETSTAT: Summary report : $SUMFILE"
