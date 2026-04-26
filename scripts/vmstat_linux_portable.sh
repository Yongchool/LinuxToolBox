#!/usr/bin/env bash
# vmstat_linux_portable.sh
#
# Portable Linux vmstat collector for:
#   - Ubuntu 22.04 / 24.04
#   - Debian 11 / 12
#   - Oracle Linux
#   - Red Hat Enterprise Linux 8 / 9
#   - SUSE Linux Enterprise Server 12 SP5 / 15 SP6
#
# Purpose:
#   - Collect vmstat interval data during a measurement window
#   - Save before/after snapshots of vmstat -s, /proc/vmstat, /proc/meminfo
#   - Generate a summarized report with interval averages and selected deltas
#
# Security / hardening notes:
#   - Strict mode enabled: set -euo pipefail
#   - Safe temp directory via mktemp -d
#   - umask 077 to protect generated temp artifacts
#   - No eval, no unquoted expansion, conservative PATH
#   - Input validation for numeric arguments
#
# Compatibility notes:
#   - Detects support for vmstat -t and -w before using them
#   - Avoids distro-specific vmstat options not portable across Linux distros
#   - Uses /proc-based fallbacks for additional counters

set -euo pipefail
IFS=$' \t\n'
umask 077
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export LANG=C
export LC_ALL=C
readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_OUT_DIR="$(pwd)"

print_usage() {
  cat <<'EOF'
Usage:
  vmstat_linux_portable.sh [-i INTERVAL] [-o OUTPUT_DIR] TOTAL_SECONDS

Arguments:
  TOTAL_SECONDS         Total collection duration in seconds (minimum: 60)

Options:
  -i INTERVAL           Sampling interval in seconds.
                        If omitted:
                          * use PERFPMR_MONITOR_INTVLTIME if set
                          * otherwise 1 if TOTAL_SECONDS < 601
                          * otherwise 10
  -o OUTPUT_DIR         Directory for output files (default: current directory)
  -h                    Show this help

Examples:
  ./vmstat_linux_portable.sh 300
  ./vmstat_linux_portable.sh -i 5 600
  ./vmstat_linux_portable.sh -o /var/tmp/vmstat_bundle 900
EOF
}

log() {
  printf '%s\n' "$*"
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { err "Required command not found: $cmd"; exit 1; }
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

safe_hostname() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || uname -n
}

read_os_info() {
  local name='unknown' version='unknown' pretty='unknown'
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    name="${NAME:-unknown}"
    version="${VERSION_ID:-unknown}"
    pretty="${PRETTY_NAME:-${NAME:-unknown}}"
  elif [[ -r /etc/SuSE-release ]]; then
    pretty='SUSE Linux Enterprise Server (legacy release file)'
    name='SUSE Linux Enterprise Server'
    version='unknown'
  fi
  printf '%s|%s|%s\n' "$name" "$version" "$pretty"
}

build_vmstat_args() {
  local interval="$1"
  local count="$2"
  local -a args=()

  if vmstat --help 2>&1 | grep -q -- ' -w'; then
    args+=("-w")
  fi
  if vmstat --help 2>&1 | grep -q -- ' -t'; then
    args+=("-t")
  fi
  args+=("$interval" "$count")
  printf '%s\n' "${args[@]}"
}

INTERVAL=''
OUT_DIR="$DEFAULT_OUT_DIR"
while getopts ':i:o:h' opt; do
  case "$opt" in
    i) INTERVAL="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    h) print_usage; exit 0 ;;
    :) err "Option -$OPTARG requires a value"; print_usage; exit 1 ;;
    \?) err "Unknown option: -$OPTARG"; print_usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

TOTAL_SECONDS="${1:-}"
[[ -n "$TOTAL_SECONDS" ]] || { print_usage; exit 1; }
is_uint "$TOTAL_SECONDS" || { err 'TOTAL_SECONDS must be a positive integer'; exit 1; }
(( TOTAL_SECONDS >= 60 )) || { err 'Minimum time interval required is 60 seconds'; exit 1; }

if [[ -n "$INTERVAL" ]]; then
  is_uint "$INTERVAL" || { err 'INTERVAL must be a positive integer'; exit 1; }
  (( INTERVAL > 0 )) || { err 'INTERVAL must be greater than 0'; exit 1; }
elif [[ -n "${PERFPMR_MONITOR_INTVLTIME:-}" ]]; then
  INTERVAL="${PERFPMR_MONITOR_INTVLTIME}"
  is_uint "$INTERVAL" || { err 'PERFPMR_MONITOR_INTVLTIME must be a positive integer'; exit 1; }
  (( INTERVAL > 0 )) || { err 'PERFPMR_MONITOR_INTVLTIME must be greater than 0'; exit 1; }
else
  if (( TOTAL_SECONDS < 601 )); then
    INTERVAL=1
  else
    INTERVAL=10
  fi
fi

require_cmd vmstat
require_cmd awk
require_cmd sed
require_cmd grep
require_cmd date
require_cmd mktemp
require_cmd uname
require_cmd cat
require_cmd hostname

mkdir -p "$OUT_DIR"
[[ -d "$OUT_DIR" ]] || { err "Failed to create output directory: $OUT_DIR"; exit 1; }
[[ -w "$OUT_DIR" ]] || { err "Output directory is not writable: $OUT_DIR"; exit 1; }
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

TMP_DIR="$(mktemp -d -p "${TMPDIR:-/tmp}" vmstat_portable.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

COUNT=$(( TOTAL_SECONDS / INTERVAL ))
COUNT=$(( COUNT + 1 ))

HOST_SHORT="$(safe_hostname)"
START_TIME="$(date '+%F %T %Z')"
readarray -t VMSTAT_ARGS < <(build_vmstat_args "$INTERVAL" "$COUNT")
OS_INFO="$(read_os_info)"
OS_NAME="${OS_INFO%%|*}"
REST="${OS_INFO#*|}"
OS_VERSION="${REST%%|*}"
OS_PRETTY="${REST#*|}"
KERNEL_REL="$(uname -r)"
ARCH="$(uname -m)"

VMSTAT_TMP="$TMP_DIR/vmstat.tmp"
VMSTAT_S_BEFORE="$TMP_DIR/vmstat_s.before"
VMSTAT_S_AFTER="$TMP_DIR/vmstat_s.after"
PROC_VMSTAT_BEFORE="$TMP_DIR/proc_vmstat.before"
PROC_VMSTAT_AFTER="$TMP_DIR/proc_vmstat.after"
MEMINFO_BEFORE="$TMP_DIR/meminfo.before"
MEMINFO_AFTER="$TMP_DIR/meminfo.after"
CPUINFO_SUMMARY="$TMP_DIR/cpuinfo.summary"
VMSTAT_AWK="$TMP_DIR/vmstat.avg.awk"
DELTA_AWK="$TMP_DIR/vmstat.delta.awk"

VMSTAT_INT="$OUT_DIR/vmstat.int"
VMSTAT_SUM="$OUT_DIR/vmstat.sum"
VMSTAT_META="$OUT_DIR/vmstat.meta"

# Metadata
{
  printf 'script=%s\n' "$SCRIPT_NAME"
  printf 'hostname=%s\n' "$HOST_SHORT"
  printf 'os_name=%s\n' "$OS_NAME"
  printf 'os_version=%s\n' "$OS_VERSION"
  printf 'os_pretty=%s\n' "$OS_PRETTY"
  printf 'kernel=%s\n' "$KERNEL_REL"
  printf 'arch=%s\n' "$ARCH"
  printf 'start_time=%s\n' "$START_TIME"
  printf 'interval=%s\n' "$INTERVAL"
  printf 'count=%s\n' "$COUNT"
  printf 'total_seconds=%s\n' "$TOTAL_SECONDS"
  printf 'out_dir=%s\n' "$OUT_DIR"
} > "$VMSTAT_META"

printf '\n\n\n V M S T A T   I N T E R V A L   O U T P U T (vmstat %s)\n' "${VMSTAT_ARGS[*]}" > "$VMSTAT_INT"
printf '\n\nHostname: %s\n' "$HOST_SHORT" >> "$VMSTAT_INT"
printf 'OS      : %s\n' "$OS_PRETTY" >> "$VMSTAT_INT"
printf 'Kernel  : %s\n' "$KERNEL_REL" >> "$VMSTAT_INT"
printf 'Arch    : %s\n' "$ARCH" >> "$VMSTAT_INT"
printf 'Start   : %s\n' "$START_TIME" >> "$VMSTAT_INT"

printf '\n\n\n V M S T A T   S U M M A R Y   O U T P U T\n' > "$VMSTAT_SUM"
printf '\n\nHostname: %s\n' "$HOST_SHORT" >> "$VMSTAT_SUM"
printf 'OS      : %s\n' "$OS_PRETTY" >> "$VMSTAT_SUM"
printf 'Kernel  : %s\n' "$KERNEL_REL" >> "$VMSTAT_SUM"
printf 'Arch    : %s\n' "$ARCH" >> "$VMSTAT_SUM"
printf 'Start   : %s\n' "$START_TIME" >> "$VMSTAT_SUM"

# Optional informational snapshot
if [[ -r /proc/cpuinfo ]]; then
  {
    awk -F': *' '/^processor[[:space:]]*:/{n+=1} /^model name[[:space:]]*:/{if (!model) model=$2} END {printf("cpu_count=%d\nmodel=%s\n", n, model)}' /proc/cpuinfo || true
  } > "$CPUINFO_SUMMARY"
fi

log 'VMSTAT: Saving statistics before run....'
vmstat -s > "$VMSTAT_S_BEFORE"
cat /proc/vmstat > "$PROC_VMSTAT_BEFORE"
cat /proc/meminfo > "$MEMINFO_BEFORE"

log 'VMSTAT: Starting Virtual Memory Statistics Collector [VMSTAT]....'
log 'VMSTAT: Waiting for measurement period to end....'
vmstat "${VMSTAT_ARGS[@]}" > "$VMSTAT_TMP"

END_TIME="$(date '+%F %T %Z')"
log 'VMSTAT: Saving statistics after run....'
vmstat -s > "$VMSTAT_S_AFTER"
cat /proc/vmstat > "$PROC_VMSTAT_AFTER"
cat /proc/meminfo > "$MEMINFO_AFTER"

printf '\nEnd     : %s\n' "$END_TIME" >> "$VMSTAT_INT"
printf '\nEnd     : %s\n' "$END_TIME" >> "$VMSTAT_SUM"
printf 'end_time=%s\n' "$END_TIME" >> "$VMSTAT_META"

cat > "$VMSTAT_AWK" <<'AWKAVG'
BEGIN {
  saw_header = 0
  skipped_first_sample = 0
  row_count = 0
}
/^[[:space:]]*r[[:space:]]+b[[:space:]]+/ {
  header = $0
  saw_header = 1
  next
}
{
  if (!saw_header) next
  if ($0 ~ /^[[:space:]]*$/) next
  if ($1 !~ /^-?[0-9]+$/) next

  # Linux vmstat prints an initial since-boot line before interval samples.
  if (!skipped_first_sample) {
    skipped_first_sample = 1
    next
  }

  row_count++
  field_count = NF
  for (i = 1; i <= NF; i++) {
    if ($i ~ /^-?[0-9]+([.][0-9]+)?$/) {
      sum[i] += $i
      numeric[i] = 1
    }
  }
}
END {
  print header
  if (row_count == 0) {
    print "No sampled rows captured."
    exit
  }
  for (i = 1; i <= field_count; i++) {
    if (i > 1) printf(" ")
    if (numeric[i]) {
      avg = sum[i] / row_count
      if (avg == int(avg)) printf("%d", avg)
      else printf("%.2f", avg)
    } else {
      printf("-")
    }
  }
  printf("\n")
}
AWKAVG

cat > "$DELTA_AWK" <<'AWKDELTA'
function loadfile(path, arr,   rc, k, v) {
  while ((rc = getline < path) > 0) {
    if ($1 != "" && $2 ~ /^-?[0-9]+$/) {
      k = $1
      v = $2
      arr[k] = v
    }
  }
  close(path)
}
BEGIN {
  loadfile(before, b)
  loadfile(after, a)
  split("pgfault pgmajfault pgpgin pgpgout pswpin pswpout pgfree pgactivate pgdeactivate pgscan_kswapd pgscan_direct pgsteal_kswapd pgsteal_direct allocstall kswapd_inodesteal oom_kill", keys, " ")
  printf("Selected /proc/vmstat deltas during measurement\n\n")
  for (i = 1; i <= length(keys); i++) {
    k = keys[i]
    if ((k in a) && (k in b)) {
      printf("%-20s %d\n", k, a[k] - b[k])
    }
  }
}
AWKDELTA

# Keep the original header and remove only the first numeric line after it.
awk '
BEGIN { saw_header=0; skipped_first_sample=0 }
/^[[:space:]]*r[[:space:]]+b[[:space:]]+/ { print; saw_header=1; next }
{
  if (!saw_header) { print; next }
  if ($1 ~ /^-?[0-9]+$/ && !skipped_first_sample) { skipped_first_sample=1; next }
  print
}
' "$VMSTAT_TMP" >> "$VMSTAT_INT"

printf '\n\n\n V M S T A T   I N T E R V A L   A V E R A G E S\n\n' >> "$VMSTAT_SUM"
awk -f "$VMSTAT_AWK" "$VMSTAT_TMP" >> "$VMSTAT_SUM"

printf '\n\n\n V M S T A T   -s   ( B E F O R E )\n\n' >> "$VMSTAT_SUM"
cat "$VMSTAT_S_BEFORE" >> "$VMSTAT_SUM"

printf '\n\n\n V M S T A T   -s   ( A F T E R )\n\n' >> "$VMSTAT_SUM"
cat "$VMSTAT_S_AFTER" >> "$VMSTAT_SUM"

printf '\n\n\n / p r o c / v m s t a t   D E L T A S\n\n' >> "$VMSTAT_SUM"
awk -v before="$PROC_VMSTAT_BEFORE" -v after="$PROC_VMSTAT_AFTER" -f "$DELTA_AWK" >> "$VMSTAT_SUM"

printf '\n\n\n / p r o c / m e m i n f o   ( B E F O R E )\n\n' >> "$VMSTAT_SUM"
cat "$MEMINFO_BEFORE" >> "$VMSTAT_SUM"

printf '\n\n\n / p r o c / m e m i n f o   ( A F T E R )\n\n' >> "$VMSTAT_SUM"
cat "$MEMINFO_AFTER" >> "$VMSTAT_SUM"

if [[ -s "$CPUINFO_SUMMARY" ]]; then
  printf '\n\n\n C P U   S U M M A R Y\n\n' >> "$VMSTAT_SUM"
  cat "$CPUINFO_SUMMARY" >> "$VMSTAT_SUM"
fi

log "VMSTAT: Interval report is in file $VMSTAT_INT"
log "VMSTAT: Summary report is in file $VMSTAT_SUM"
log "VMSTAT: Metadata report is in file $VMSTAT_META"
