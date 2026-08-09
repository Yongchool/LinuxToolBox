#!/bin/sh
# collect_mpstat_perf.sh
#
# Portable Linux CPU / IRQ / softirq performance evidence collector.
#
# Purpose:
#   - Collect per-CPU utilization with mpstat.
#   - Correlate CPU usage with hard IRQ and softirq activity.
#   - Preserve /proc/stat, /proc/interrupts, /proc/softirqs, PSI, and affinity context.
#   - Support duration/interval based collection similar to the existing perf collectors.
#
# Supported targets:
#   Ubuntu 22.04 / 24.04
#   Debian 11 / 12
#   Oracle Linux
#   Red Hat Enterprise Linux 8 / 9
#   SUSE Linux Enterprise Server 12 SP5 / 15 SP6
#
# Requirements:
#   /bin/sh, mpstat (sysstat), awk, sed, grep, date, mkdir, cat, uname
#
# Modes:
#   basic  : mpstat per-CPU utilization + before/after kernel CPU/IRQ snapshots
#   detail : basic + IRQ affinity, CPU topology, PSI, scheduler and network queue context
#   full   : detail + optional pidstat/sar task and interrupt correlation
#
# Examples:
#   ./collect_mpstat_perf.sh -o /var/tmp/mpstat_bundle
#   ./collect_mpstat_perf.sh -d 600 -i 10 -m detail -o /var/tmp/mpstat_detail
#   ./collect_mpstat_perf.sh -d 1800 -i 5 -m full --compress -o /var/tmp/mpstat_full

LC_ALL=C
export LC_ALL
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

DURATION=600
INTERVAL=10
MODE=basic
OUTDIR=
COMPRESS=0
SCRIPT_NAME=${0##*/}

usage() {
    cat <<'EOF_USAGE'
Usage:
  collect_mpstat_perf.sh [options]

Options:
  -o DIR      Output directory. Default: ./mpstat_bundle_YYYYmmdd_HHMMSS
  -d SEC      Total collection duration in seconds. Default: 600
  -i SEC      Sampling interval in seconds. Default: 10
  -m MODE     Collection mode: basic, detail, full. Default: basic
  --compress  Create tar.gz archive at the end when tar and gzip are available.
  -h, --help  Show this help.

Modes:
  basic:
    - mpstat -P ALL interval data
    - /proc/stat before/after
    - /proc/interrupts before/after
    - /proc/softirqs before/after
    - CPU online/present/isolated state

  detail:
    - basic
    - per-IRQ affinity and effective affinity where available
    - CPU topology and NUMA node mapping
    - /proc/pressure/cpu
    - scheduler-related sysctl values
    - NIC queue/RPS/XPS context

  full:
    - detail
    - pidstat CPU/task-switch statistics when available
    - sar CPU/interrupt statistics when available

Notes:
  mpstat is provided by the sysstat package.
  The collector is read-only and does not modify IRQ affinity, RPS/XPS, sysctl,
  scheduler, or network configuration.
EOF_USAGE
}

log() {
    printf '%s\n' "$*" >&2
}

error_exit() {
    log "ERROR: $*"
    exit 1
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

is_uint() {
    case ${1-} in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

safe_read() {
    file=$1
    if [ -r "$file" ]; then
        cat "$file" 2>/dev/null || printf 'READ_FAILED: %s\n' "$file"
    else
        printf 'UNREADABLE_OR_NOT_PRESENT: %s\n' "$file"
    fi
}

flatten_file() {
    file=$1
    if [ -r "$file" ]; then
        tr '\n' ' ' < "$file" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g; s/[[:space:]]*$//'
        printf '\n'
    else
        printf 'UNREADABLE_OR_NOT_PRESENT\n'
    fi
}

now_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case $1 in
            -o)
                [ "$#" -ge 2 ] || error_exit '-o requires a directory'
                OUTDIR=$2
                shift 2
                ;;
            -d)
                [ "$#" -ge 2 ] || error_exit '-d requires seconds'
                DURATION=$2
                shift 2
                ;;
            -i)
                [ "$#" -ge 2 ] || error_exit '-i requires seconds'
                INTERVAL=$2
                shift 2
                ;;
            -m)
                [ "$#" -ge 2 ] || error_exit '-m requires a mode'
                MODE=$2
                shift 2
                ;;
            --compress)
                COMPRESS=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error_exit "unknown option: $1"
                ;;
        esac
    done
}

validate_args() {
    is_uint "$DURATION" || error_exit 'duration must be a positive integer'
    is_uint "$INTERVAL" || error_exit 'interval must be a positive integer'
    [ "$DURATION" -gt 0 ] || error_exit 'duration must be greater than 0'
    [ "$INTERVAL" -gt 0 ] || error_exit 'interval must be greater than 0'

    case $MODE in
        basic|detail|full) : ;;
        *) error_exit "invalid mode: $MODE" ;;
    esac

    have_cmd mpstat || error_exit 'mpstat is required. Install the sysstat package.'
    have_cmd awk || error_exit 'awk is required'
    have_cmd sed || error_exit 'sed is required'
    have_cmd grep || error_exit 'grep is required'
    have_cmd date || error_exit 'date is required'
    have_cmd mkdir || error_exit 'mkdir is required'
    have_cmd cat || error_exit 'cat is required'
    have_cmd uname || error_exit 'uname is required'

    if [ -z "$OUTDIR" ]; then
        OUTDIR="./mpstat_bundle_$(date +%Y%m%d_%H%M%S)"
    fi
}

prepare_dirs() {
    mkdir -p \
        "$OUTDIR/raw" \
        "$OUTDIR/proc/before" \
        "$OUTDIR/proc/after" \
        "$OUTDIR/static" \
        "$OUTDIR/irq" \
        "$OUTDIR/cpu" \
        "$OUTDIR/net" \
        "$OUTDIR/optional" \
        "$OUTDIR/summary" || error_exit "failed to create output directory: $OUTDIR"
}

count_samples() {
    # mpstat prints one report per interval. Round up so the requested duration is covered.
    awk -v d="$DURATION" -v i="$INTERVAL" 'BEGIN { n=int(d/i); if (d%i) n++; if (n<1) n=1; print n }'
}

mpstat_supports_irq() {
    mpstat -V >/dev/null 2>&1 || true
    mpstat --help 2>&1 | grep -q -- '-I'
}

save_metadata() {
    samples=$(count_samples)
    {
        printf 'script=%s\n' "$SCRIPT_NAME"
        printf 'started_at_utc=%s\n' "$(now_utc)"
        printf 'duration=%s\n' "$DURATION"
        printf 'interval=%s\n' "$INTERVAL"
        printf 'samples=%s\n' "$samples"
        printf 'mode=%s\n' "$MODE"
        printf 'outdir=%s\n' "$OUTDIR"
        printf '\n[hostname]\n'
        hostname 2>/dev/null || uname -n
        printf '\n[kernel]\n'
        uname -a
        printf '\n[os-release]\n'
        safe_read /etc/os-release
        printf '\n[mpstat version]\n'
        mpstat -V 2>&1 || true
        printf '\n[commands]\n'
        for cmd in mpstat pidstat sar lscpu numactl ethtool ip ps top tar gzip; do
            if have_cmd "$cmd"; then
                printf '%s=YES path=%s\n' "$cmd" "$(command -v "$cmd")"
            else
                printf '%s=NO\n' "$cmd"
            fi
        done
    } > "$OUTDIR/00_metadata.txt"
}

capture_proc_phase() {
    phase=$1
    dir="$OUTDIR/proc/$phase"

    safe_read /proc/stat > "$dir/proc_stat.txt"
    safe_read /proc/interrupts > "$dir/proc_interrupts.txt"
    safe_read /proc/softirqs > "$dir/proc_softirqs.txt"
    safe_read /proc/schedstat > "$dir/proc_schedstat.txt"
    safe_read /proc/loadavg > "$dir/proc_loadavg.txt"
    safe_read /proc/pressure/cpu > "$dir/pressure_cpu.txt"
}

capture_cpu_context() {
    {
        printf '[online]\n'
        safe_read /sys/devices/system/cpu/online
        printf '\n[present]\n'
        safe_read /sys/devices/system/cpu/present
        printf '\n[possible]\n'
        safe_read /sys/devices/system/cpu/possible
        printf '\n[isolated]\n'
        safe_read /sys/devices/system/cpu/isolated
        printf '\n[nohz_full]\n'
        safe_read /sys/devices/system/cpu/nohz_full
        printf '\n[kernel cmdline]\n'
        safe_read /proc/cmdline
    } > "$OUTDIR/cpu/cpu_state.txt"

    if have_cmd lscpu; then
        lscpu > "$OUTDIR/cpu/lscpu.txt" 2>&1 || true
        lscpu -e > "$OUTDIR/cpu/lscpu_extended.txt" 2>&1 || true
    fi

    : > "$OUTDIR/cpu/topology.txt"
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$cpu_dir" ] || continue
        cpu=${cpu_dir##*/cpu}
        printf 'cpu=%s package=' "$cpu" >> "$OUTDIR/cpu/topology.txt"
        flatten_file "$cpu_dir/topology/physical_package_id" >> "$OUTDIR/cpu/topology.txt"
        printf 'cpu=%s core=' "$cpu" >> "$OUTDIR/cpu/topology.txt"
        flatten_file "$cpu_dir/topology/core_id" >> "$OUTDIR/cpu/topology.txt"
        printf 'cpu=%s thread_siblings=' "$cpu" >> "$OUTDIR/cpu/topology.txt"
        flatten_file "$cpu_dir/topology/thread_siblings_list" >> "$OUTDIR/cpu/topology.txt"
    done
}

capture_irq_affinity() {
    out="$OUTDIR/irq/irq_affinity.txt"
    : > "$out"

    for irq_dir in /proc/irq/[0-9]*; do
        [ -d "$irq_dir" ] || continue
        irq=${irq_dir##*/}
        printf 'IRQ=%s affinity=' "$irq" >> "$out"
        flatten_file "$irq_dir/smp_affinity_list" >> "$out"

        if [ -r "$irq_dir/effective_affinity_list" ]; then
            printf 'IRQ=%s effective=' "$irq" >> "$out"
            flatten_file "$irq_dir/effective_affinity_list" >> "$out"
        fi

        if [ -r "$irq_dir/node" ]; then
            printf 'IRQ=%s node=' "$irq" >> "$out"
            flatten_file "$irq_dir/node" >> "$out"
        fi
    done
}

capture_scheduler_context() {
    out="$OUTDIR/static/scheduler_context.txt"
    {
        for file in \
            /proc/sys/kernel/sched_autogroup_enabled \
            /proc/sys/kernel/sched_cfs_bandwidth_slice_us \
            /proc/sys/kernel/sched_rr_timeslice_ms \
            /proc/sys/kernel/sched_rt_period_us \
            /proc/sys/kernel/sched_rt_runtime_us \
            /proc/sys/kernel/watchdog \
            /proc/sys/kernel/watchdog_thresh \
            /proc/sys/kernel/softlockup_panic \
            /proc/sys/kernel/hardlockup_panic; do
            printf '%s=' "$file"
            flatten_file "$file"
        done
    } > "$out"
}

capture_network_queue_context() {
    out="$OUTDIR/net/queue_affinity.txt"
    : > "$out"

    for dev_dir in /sys/class/net/*; do
        [ -d "$dev_dir" ] || continue
        dev=${dev_dir##*/}
        [ "$dev" = lo ] && continue

        for queue_dir in "$dev_dir"/queues/rx-*; do
            [ -d "$queue_dir" ] || continue
            queue=${queue_dir##*/}
            printf 'dev=%s queue=%s rps_cpus=' "$dev" "$queue" >> "$out"
            flatten_file "$queue_dir/rps_cpus" >> "$out"
            printf 'dev=%s queue=%s rps_flow_cnt=' "$dev" "$queue" >> "$out"
            flatten_file "$queue_dir/rps_flow_cnt" >> "$out"
        done

        for queue_dir in "$dev_dir"/queues/tx-*; do
            [ -d "$queue_dir" ] || continue
            queue=${queue_dir##*/}
            printf 'dev=%s queue=%s xps_cpus=' "$dev" "$queue" >> "$out"
            flatten_file "$queue_dir/xps_cpus" >> "$out"
        done
    done
}

run_mpstat_cpu() {
    samples=$(count_samples)
    log "Collecting mpstat per-CPU data: interval=$INTERVAL samples=$samples"
    mpstat -P ALL "$INTERVAL" "$samples" > "$OUTDIR/raw/mpstat_cpu.txt" 2>&1
}

run_mpstat_irq_background() {
    case $MODE in
        detail|full) : ;;
        *) MPSTAT_IRQ_PID=; return 0 ;;
    esac

    if mpstat_supports_irq; then
        samples=$(count_samples)
        log 'Collecting mpstat interrupt data concurrently'
        mpstat -I ALL -P ALL "$INTERVAL" "$samples" > "$OUTDIR/raw/mpstat_irq.txt" 2>&1 &
        MPSTAT_IRQ_PID=$!
    else
        MPSTAT_IRQ_PID=
        printf 'mpstat -I is not supported by this sysstat version\n' > "$OUTDIR/raw/mpstat_irq_not_supported.txt"
    fi
}

run_optional_collectors() {
    [ "$MODE" = full ] || return 0
    samples=$(count_samples)

    if have_cmd pidstat; then
        pidstat -u -w -t "$INTERVAL" "$samples" > "$OUTDIR/optional/pidstat_cpu_switch.txt" 2>&1 &
        PIDSTAT_PID=$!
    else
        PIDSTAT_PID=
    fi

    if have_cmd sar; then
        sar -u ALL "$INTERVAL" "$samples" > "$OUTDIR/optional/sar_cpu.txt" 2>&1 &
        SAR_CPU_PID=$!
        sar -I SUM "$INTERVAL" "$samples" > "$OUTDIR/optional/sar_irq_sum.txt" 2>&1 &
        SAR_IRQ_PID=$!
    else
        SAR_CPU_PID=
        SAR_IRQ_PID=
    fi
}

wait_optional_collectors() {
    for pid in ${MPSTAT_IRQ_PID-} ${PIDSTAT_PID-} ${SAR_CPU_PID-} ${SAR_IRQ_PID-}; do
        [ -n "$pid" ] || continue
        wait "$pid" 2>/dev/null || true
    done
}

generate_deltas() {
    # /proc/stat CPU jiffy delta by CPU and field.
    awk '
        NR==FNR && /^cpu[0-9]*[[:space:]]/ {
            cpu=$1
            for (i=2; i<=NF; i++) before[cpu,i]=$i
            fields[cpu]=NF
            next
        }
        /^cpu[0-9]*[[:space:]]/ {
            cpu=$1
            printf "%s", cpu
            max=fields[cpu]
            if (NF < max) max=NF
            for (i=2; i<=max; i++) printf " %d", ($i-before[cpu,i])
            printf "\n"
        }
    ' "$OUTDIR/proc/before/proc_stat.txt" "$OUTDIR/proc/after/proc_stat.txt" \
        > "$OUTDIR/summary/proc_stat_cpu_delta.txt" 2>/dev/null || true

    {
        printf '# Columns follow /proc/stat CPU order:\n'
        printf '# cpu user nice system idle iowait irq softirq steal guest guest_nice\n'
        cat "$OUTDIR/summary/proc_stat_cpu_delta.txt" 2>/dev/null || true
    } > "$OUTDIR/summary/proc_stat_cpu_delta.with_header.txt"

    # Softirq counter delta preserving the per-CPU layout from /proc/softirqs.
    awk '
        NR==FNR {
            if ($1 ~ /:$/) {
                key=$1
                for (i=2; i<=NF; i++) before[key,i]=$i
                max[key]=NF
            }
            next
        }
        $1 ~ /:$/ {
            key=$1
            printf "%s", key
            limit=max[key]
            if (NF < limit) limit=NF
            for (i=2; i<=limit; i++) printf " %d", ($i-before[key,i])
            printf "\n"
        }
    ' "$OUTDIR/proc/before/proc_softirqs.txt" "$OUTDIR/proc/after/proc_softirqs.txt" \
        > "$OUTDIR/summary/proc_softirqs_delta.txt" 2>/dev/null || true
}

compress_output() {
    [ "$COMPRESS" -eq 1 ] || return 0

    if have_cmd tar && have_cmd gzip; then
        parent=$(dirname "$OUTDIR")
        base=${OUTDIR##*/}
        archive="$OUTDIR.tar.gz"
        tar -C "$parent" -czf "$archive" "$base" 2>/dev/null || {
            log 'WARNING: archive creation failed'
            return 0
        }
        log "Archive: $archive"
    else
        log 'WARNING: --compress requested but tar/gzip are unavailable'
    fi
}

main() {
    parse_args "$@"
    validate_args
    prepare_dirs
    save_metadata

    capture_proc_phase before
    capture_cpu_context

    case $MODE in
        detail|full)
            capture_irq_affinity
            capture_scheduler_context
            capture_network_queue_context
            ;;
    esac

    # Related collectors run concurrently so all data covers the same incident window.
    run_mpstat_irq_background
    run_optional_collectors
    run_mpstat_cpu
    wait_optional_collectors

    capture_proc_phase after
    generate_deltas

    {
        printf 'completed_at_utc=%s\n' "$(now_utc)"
        printf 'duration_requested=%s\n' "$DURATION"
        printf 'interval=%s\n' "$INTERVAL"
        printf 'mode=%s\n' "$MODE"
    } > "$OUTDIR/99_completed.txt"

    compress_output
    log "Completed: $OUTDIR"
}

main "$@"
