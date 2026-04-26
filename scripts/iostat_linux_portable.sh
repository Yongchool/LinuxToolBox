#!/usr/bin/env bash
# iostat_linux_portable.sh
# Portable Linux iostat collector (Ubuntu/Debian/RHEL/OL/SLES)
set -euo pipefail
IFS=$' 	
'
umask 077
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export LANG=C LC_ALL=C

usage(){ echo "Usage: $0 [-i INTERVAL] [-o OUT_DIR] TOTAL_SECONDS"; }
err(){ echo "ERROR: $*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; exit 1; }; }
uint(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }
opt(){ "$1" --help 2>&1 | grep -q -- " $2"; }

INTERVAL=""; OUT_DIR="."
while getopts ':i:o:h' o; do
  case "$o" in
    i) INTERVAL="$OPTARG";;
    o) OUT_DIR="$OPTARG";;
    h) usage; exit 0;;
    :) err "-$OPTARG requires a value"; exit 1;;
    \?) err "Unknown option -$OPTARG"; exit 1;;
  esac
done
shift $((OPTIND-1))
TOTAL="${1:-}"; [[ -n "$TOTAL" ]] || { usage; exit 1; }
uint "$TOTAL" || { err "TOTAL_SECONDS must be integer"; exit 1; }
(( TOTAL >= 60 )) || { err "Minimum time interval required is 60 seconds"; exit 1; }

if [[ -n "$INTERVAL" ]]; then uint "$INTERVAL" || { err "INTERVAL must be integer"; exit 1; }
elif [[ -n "${PERFPMR_MONITOR_INTVLTIME:-}" ]]; then INTERVAL="$PERFPMR_MONITOR_INTVLTIME"; uint "$INTERVAL" || { err "PERFPMR_MONITOR_INTVLTIME must be integer"; exit 1; }
else if (( TOTAL < 601 )); then INTERVAL=10; else INTERVAL=60; fi
fi
(( INTERVAL > 0 )) || { err "INTERVAL must be > 0"; exit 1; }

need iostat; need awk; need date; need grep; need sed; need mktemp; need cat; need uname; need hostname
mkdir -p "$OUT_DIR"; OUT_DIR="$(cd "$OUT_DIR" && pwd)"
TMP="$(mktemp -d -p "${TMPDIR:-/tmp}" iostat_portable.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

COUNT=$(( TOTAL / INTERVAL + 1 ))
RAW="$TMP/iostat.raw"; AVG_AWK="$TMP/avg.awk"
INTFILE="$OUT_DIR/iostat.int"; SUMFILE="$OUT_DIR/iostat.sum"; METAFILE="$OUT_DIR/iostat.meta"; PATHFILE="$OUT_DIR/iostat.path"

IOSTAT_ARGS=(); opt iostat '-y' && IOSTAT_ARGS+=('-y'); opt iostat '-m' && IOSTAT_ARGS+=('-m'); opt iostat '-x' && IOSTAT_ARGS+=('-x')
IOSTAT_ARGS+=("$INTERVAL" "$COUNT")

{
  echo "script=iostat_linux_portable.sh";
  echo "hostname=$(hostname -s 2>/dev/null || hostname || true)";
  echo "kernel=$(uname -r)";
  echo "arch=$(uname -m)";
  echo "start_time=$(date '+%F %T %Z')";
  echo "interval=$INTERVAL";
  echo "count=$COUNT";
  echo "total_seconds=$TOTAL";
  echo "iostat_args=${IOSTAT_ARGS[*]}";
} > "$METAFILE"

printf "


 I O S T A T  I N T E R V A L  O U T P U T (iostat %s)
" "${IOSTAT_ARGS[*]}" > "$INTFILE"
{
  echo "
Topology:";
  lsblk -o NAME,KNAME,TYPE,SIZE,ROTA,MOUNTPOINT,FSTYPE 2>/dev/null || true
  echo "
/proc/diskstats:";
  cat /proc/diskstats 2>/dev/null || true
} > "$PATHFILE"

iostat "${IOSTAT_ARGS[@]}" > "$RAW"
cat "$RAW" >> "$INTFILE"

cat > "$AVG_AWK" <<'AWK'
/^avg-cpu:/ { getline; if (NF){rows++; for(i=1;i<=NF;i++) s[i]+=$i} next }
/^Device/ {
  hdr=$0
  while ((getline line)>0) {
    if (line ~ /^[[:space:]]*$/) break
    if (line ~ /^Device/) continue
    n=split(line,f,/[^[:graph:]]+/)
    d=f[1]; if(d=="") continue
    c[d]++; if(n>m) m=n
    for(i=2;i<=n;i++) if (f[i] ~ /^-?[0-9.]+$/) ds[d,i]+=f[i]
  }
}
END{
  print "CPU averages"; print "------------";
  if(rows){ for(i=1;i<=6;i++) printf(i==1?"%.2f":" %.2f", s[i]/rows); printf("
") } else print "No CPU parsed";
  print "
Per-device averages"; print "-------------------";
  if(!hdr){ print "No Device section parsed"; exit }
  print hdr
  for(d in c){ printf "%s", d; for(i=2;i<=m;i++){ if(((d SUBSEP i) in ds)) printf " %.2f", ds[d,i]/c[d]; else printf " -" } printf "
" }
}
AWK

printf "

Interval averages
=================
" > "$SUMFILE"
awk -f "$AVG_AWK" "$RAW" >> "$SUMFILE" || echo "Failed to parse averages" >> "$SUMFILE"
printf "

Path/topology
=============
" >> "$SUMFILE"
cat "$PATHFILE" >> "$SUMFILE"

echo "IOSTAT: Interval report: $INTFILE"
echo "IOSTAT: Summary report : $SUMFILE"
