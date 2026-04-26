#!/usr/bin/env bash
# iostat_linux_portable.sh
# Portable Linux iostat collector
# Target: Ubuntu / Debian / Oracle Linux / RHEL / SUSE

set -euo pipefail
IFS=$' \t\n'
umask 077
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export LANG=C
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage:
  iostat_linux_portable.sh [-i INTERVAL] [-o OUT_DIR] TOTAL_SECONDS

Options:
  -i INTERVAL   Sampling interval in seconds
  -o OUT_DIR    Output directory (default: current directory)
  -h            Show help

Arguments:
  TOTAL_SECONDS Total collection duration in seconds (minimum 60)
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

opt_supported() {
  local cmd="$1"
  local opt="$2"
  "$cmd" --help 2>&1 | grep -q -- " $opt"
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

INTERVAL=''
OUT_DIR='.'

while getopts ':i:o:h' opt; do
  case "$opt" in
    i) INTERVAL="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) err "Option -$OPTARG requires a value"; exit 1 ;;
    \?) err "Unknown option -$OPTARG"; exit 1 ;;
  esac
done

shift $((OPTIND - 1))

TOTAL="${1:-}"
[[ -n "$TOTAL" ]] || { usage; exit 1; }
uint "$TOTAL" || { err "TOTAL_SECONDS must be a positive integer"; exit 1; }
(( TOTAL >= 60 )) || { err "Minimum time interval required is 60 seconds"; exit 1; }

if [[ -n "$INTERVAL" ]]; then
  uint "$INTERVAL" || { err "INTERVAL must be a positive integer"; exit 1; }
elif [[ -n "${PERFPMR_MONITOR_INTVLTIME:-}" ]]; then
  INTERVAL="${PERFPMR_MONITOR_INTVLTIME}"
  uint "$INTERVAL" || { err "PERFPMR_MONITOR_INTVLTIME must be a positive integer"; exit 1; }
else
  if (( TOTAL < 601 )); then
    INTERVAL=10
  else
    INTERVAL=60
  fi
fi

(( INTERVAL > 0 )) || { err "INTERVAL must be greater than 0"; exit 1; }

need iostat
need awk
need date
need grep
need sed
need mktemp
need cat
need uname

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

TMP_DIR="$(mktemp -d -p "${TMPDIR:-/tmp}" iostat_portable.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

COUNT=$(( TOTAL / INTERVAL + 1 ))
START_TIME="$(date '+%F %T %Z')"
HOST="$(safe_hostname)"
OS_INFO="$(read_os_info)"
OS_NAME="${OS_INFO%%|*}"
REST="${OS_INFO#*|}"
OS_VER="${REST%%|*}"
OS_PRETTY="${REST#*|}"
KERNEL="$(uname -r)"
ARCH="$(uname -m)"

RAW="$TMP_DIR/iostat.raw"
AVG_AWK="$TMP_DIR/avg.awk"

INTFILE="$OUT_DIR/iostat.int"
SUMFILE="$OUT_DIR/iostat.sum"
METAFILE="$OUT_DIR/iostat.meta"
PATHFILE="$OUT_DIR/iostat.path"

IOSTAT_ARGS=()
if opt_supported iostat '-y'; then
  IOSTAT_ARGS+=('-y')
fi
if opt_supported iostat '-m'; then
  IOSTAT_ARGS+=('-m')
fi
if opt_supported iostat '-x'; then
  IOSTAT_ARGS+=('-x')
fi
IOSTAT_ARGS+=("$INTERVAL" "$COUNT")

{
  echo "script=iostat_linux_portable.sh"
  echo "hostname=$HOST"
  echo "os_name=$OS_NAME"
  echo "os_version=$OS_VER"
  echo "os_pretty=$OS_PRETTY"
  echo "kernel=$KERNEL"
  echo "arch=$ARCH"
  echo "start_time=$START_TIME"
  echo "interval=$INTERVAL"
  echo "count=$COUNT"
  echo "total_seconds=$TOTAL"
  echo "iostat_args=${IOSTAT_ARGS[*]}"
} > "$METAFILE"

printf "\n\n\n I O S T A T  I N T E R V A L  O U T P U T (iostat %s)\n" "${IOSTAT_ARGS[*]}" > "$INTFILE"
printf "\nHostname: %s\n" "$HOST" >> "$INTFILE"
printf "OS      : %s\n" "$OS_PRETTY" >> "$INTFILE"
printf "Kernel  : %s\n" "$KERNEL" >> "$INTFILE"
printf "Arch    : %s\n" "$ARCH" >> "$INTFILE"
printf "Start   : %s\n" "$START_TIME" >> "$INTFILE"

printf "\n\n\n I O S T A T  S U M M A R Y  O U T P U T\n" > "$SUMFILE"
printf "\nHostname: %s\n" "$HOST" >> "$SUMFILE"
printf "OS      : %s\n" "$OS_PRETTY" >> "$SUMFILE"
printf "Kernel  : %s\n" "$KERNEL" >> "$SUMFILE"
printf "Arch    : %s\n" "$ARCH" >> "$SUMFILE"
printf "Start   : %s\n" "$START_TIME" >> "$SUMFILE"

{
  echo "lsblk"
  echo "-----"
  if command -v lsblk >/dev/null 2>&1; then
    lsblk -o NAME,KNAME,TYPE,SIZE,ROTA,MOUNTPOINT,FSTYPE 2>/dev/null || true
  else
    echo "lsblk not available"
  fi

  echo
  echo "/proc/diskstats"
  echo "---------------"
  cat /proc/diskstats 2>/dev/null || true

  echo
  echo "findmnt"
  echo "-------"
  if command -v findmnt >/dev/null 2>&1; then
    findmnt 2>/dev/null || true
  else
    echo "findmnt not available"
  fi

  echo
  echo "multipath"
  echo "---------"
  if command -v multipath >/dev/null 2>&1; then
    multipath -ll 2>/dev/null || true
  else
    echo "multipath not available"
  fi
} > "$PATHFILE"

echo "IOSTAT: Starting I/O Statistics Collector [IOSTAT]...."
iostat "${IOSTAT_ARGS[@]}" > "$RAW"

END_TIME="$(date '+%F %T %Z')"
printf "\nEnd     : %s\n" "$END_TIME" >> "$INTFILE"
printf "end_time=%s\n" "$END_TIME" >> "$METAFILE"

cat "$RAW" >> "$INTFILE"

cat > "$AVG_AWK" <<'AWK'
/^avg-cpu:/ {
  getline
  if (NF) {
    rows++
    for (i = 1; i <= NF; i++) {
      s[i] += $i
    }
  }
  next
}

/^Device/ {
  hdr = $0
  while ((getline line) > 0) {
    if (line ~ /^[[:space:]]*$/) {
      break
    }
    if (line ~ /^Device/) {
      continue
    }

    n = split(line, f, /[^[:graph:]]+/)
    d = f[1]

    if (d == "") {
      continue
    }

    c[d]++
    if (n > m) {
      m = n
    }

    for (i = 2; i <= n; i++) {
      if (f[i] ~ /^-?[0-9.]+$/) {
        ds[d, i] += f[i]
      }
    }
  }
}

END {
  print "CPU averages"
  print "------------"

  if (rows) {
    for (i = 1; i <= 6; i++) {
      if (i == 1) {
        printf "%.2f", s[i] / rows
      } else {
        printf " %.2f", s[i] / rows
      }
    }
    printf "\n"
  } else {
    print "No CPU parsed"
  }

  print ""
  print "Per-device averages"
  print "-------------------"

  if (!hdr) {
    print "No Device section parsed"
    exit
  }

  print hdr

  for (d in c) {
    printf "%s", d
    for (i = 2; i <= m; i++) {
      if (((d SUBSEP i) in ds)) {
        printf " %.2f", ds[d, i] / c[d]
      } else {
        printf " -"
      }
    }
    printf "\n"
  }
}
AWK

printf "\n\nInterval averages\n=================\n" >> "$SUMFILE"
awk -f "$AVG_AWK" "$RAW" >> "$SUMFILE" || {
  echo "Failed to parse interval averages" >> "$SUMFILE"
}

printf "\n\nPath/topology\n=============\n" >> "$SUMFILE"
cat "$PATHFILE" >> "$SUMFILE"

echo "IOSTAT: Interval report: $INTFILE"
echo "IOSTAT: Summary report : $SUMFILE"
echo "IOSTAT: Path report    : $PATHFILE"
echo "IOSTAT: Metadata report: $METAFILE"
