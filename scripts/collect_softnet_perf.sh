#!/bin/sh
# collect_softnet_perf.sh
#
# Portable Linux softnet / IRQ / NIC receive-path performance evidence collector.
#
# Purpose:
#   - Collect /proc/net/softnet_stat as per-CPU raw and parsed counters.
#   - Correlate softnet processing with /proc/softirqs and /proc/interrupts.
#   - Collect interface and NIC driver counters for receive/transmit queue analysis.
#   - Preserve IRQ affinity, RPS/XPS, RSS, channel, offload, and driver context.
#   - Generate per-interval softnet deltas and rates for incident correlation.
#
# Supported targets:
#   Ubuntu 22.04 / 24.04
#   Debian 11 / 12
#   Oracle Linux
#   Red Hat Enterprise Linux 8 / 9
#   SUSE Linux Enterprise Server 12 SP5 / 15 SP6
#
# Requirements:
#   /bin/sh, awk, sed, grep, date, mkdir, cat, uname, sleep
#
# Optional tools:
#   ip, ethtool, tc, nstat, lscpu, numactl, tar, gzip
#
# Modes:
#   basic  : softnet_stat + softirqs + interrupts + interface stats every interval
#   detail : basic + ethtool -S and qdisc counters + start/end IRQ/RPS/XPS/NIC context
#   full   : detail + queue sysfs, nstat, and additional per-interface driver context
#
# Examples:
#   ./collect_softnet_perf.sh -o /var/tmp/softnet_bundle
#   ./collect_softnet_perf.sh -d 1800 -i 5 -m detail -o /var/tmp/perf_case/softnet
#   ./collect_softnet_perf.sh -d 1800 -i 5 -m full -I eth0,eth1 --compress -o /var/tmp/softnet_full

LC_ALL=C
export LC_ALL
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

DURATION=600
INTERVAL=5
MODE=detail
OUTDIR=
IFACES=
COMPRESS=0
SCRIPT_NAME=${0##*/}
START_EPOCH=
END_EPOCH=
SAMPLE_ID=0
PREV_PARSED=
PREV_EPOCH=

usage() {
    cat <<'EOF_USAGE'
Usage:
  collect_softnet_perf.sh [options]

Options:
  -o DIR      Output directory. Default: ./softnet_bundle_YYYYmmdd_HHMMSS
  -d SEC      Total collection duration in seconds. Default: 600
  -i SEC      Sampling interval in seconds. Default: 5
  -m MODE     Collection mode: basic, detail, full. Default: detail
  -I LIST     Comma-separated interfaces. Default: all non-loopback interfaces
  --compress  Create tar.gz archive at the end when tar and gzip are available.
  -h, --help  Show this help.

Modes:
  basic:
    - /proc/net/softnet_stat every interval
    - parsed per-CPU processed/dropped/time_squeeze counters
    - /proc/softirqs and /proc/interrupts every interval
    - ip -s link, or /proc/net/dev fallback
    - per-interval softnet delta/rate summary

  detail:
    - basic
    - ethtool -S for selected interfaces every interval when available
    - tc -s qdisc every interval when available
    - IRQ affinity/effective affinity at start and end
    - RPS/XPS queue configuration at start and end
    - ethtool driver/offload/channel/RSS context at start and end

  full:
    - detail
    - queue-level sysfs statistics every interval
    - nstat every interval when available
    - additional interface sysfs context at start and end

Notes:
  /proc/net/softnet_stat fields are hexadecimal kernel counters. The first three
  fields are processed, dropped, and time_squeeze. Later fields vary by kernel;
  raw data is always preserved. Parsed output also records commonly used fields
  9-11 as cpu_collision, received_rps, and flow_limit_count when present.

  This collector is read-only. It does not change IRQ affinity, RSS, RPS/XPS,
  qdisc, offload, NIC channels, sysctl, or network configuration.
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

now_epoch() {
    date +%s
}

now_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
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

sanitize_name() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
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
            -I)
                [ "$#" -ge 2 ] || error_exit '-I requires a comma-separated interface list'
                IFACES=$2
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

    for cmd in awk sed grep date mkdir cat uname sleep tr; do
        have_cmd "$cmd" || error_exit "required command not found: $cmd"
    done

    [ -r /proc/net/softnet_stat ] || error_exit '/proc/net/softnet_stat is not readable'
    [ -r /proc/softirqs ] || error_exit '/proc/softirqs is not readable'
    [ -r /proc/interrupts ] || log 'WARNING: /proc/interrupts is not readable; IRQ snapshots will contain an error marker'

    if [ -z "$OUTDIR" ]; then
        OUTDIR="./softnet_bundle_$(date +%Y%m%d_%H%M%S)"
    fi
}

prepare_dirs() {
    mkdir -p \
        "$OUTDIR/snapshots" \
        "$OUTDIR/context/start" \
        "$OUTDIR/context/end" \
        "$OUTDIR/summary" || error_exit "failed to create output directory: $OUTDIR"
}

auto_interfaces() {
    found=0
    for path in /sys/class/net/*; do
        [ -e "$path" ] || continue
        iface=${path##*/}
        [ "$iface" = lo ] && continue
        printf '%s\n' "$iface"
        found=1
    done
    [ "$found" -eq 1 ] || return 0
}

selected_interfaces() {
    if [ -n "$IFACES" ]; then
        old_ifs=$IFS
        IFS=,
        for iface in $IFACES; do
            IFS=$old_ifs
            iface=$(printf '%s' "$iface" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -n "$iface" ] && printf '%s\n' "$iface"
            IFS=,
        done
        IFS=$old_ifs
    else
        auto_interfaces
    fi
}

validate_interfaces() {
    if [ -n "$IFACES" ]; then
        selected_interfaces | while IFS= read -r iface; do
            [ -e "/sys/class/net/$iface" ] || printf 'WARNING: interface not found: %s\n' "$iface" >&2
        done
    fi
}

save_metadata() {
    {
        printf 'script=%s\n' "$SCRIPT_NAME"
        printf 'started_at_utc=%s\n' "$(now_utc)"
        printf 'duration=%s\n' "$DURATION"
        printf 'interval=%s\n' "$INTERVAL"
        printf 'mode=%s\n' "$MODE"
        printf 'outdir=%s\n' "$OUTDIR"
        printf 'interfaces_requested=%s\n' "${IFACES:-auto_all_non_loopback}"
        printf '\n[selected_interfaces]\n'
        selected_interfaces
        printf '\n[hostname]\n'
        hostname 2>/dev/null || uname -n
        printf '\n[kernel]\n'
        uname -a
        printf '\n[os-release]\n'
        safe_read /etc/os-release
        printf '\n[commands]\n'
        for cmd in ip ethtool tc nstat lscpu numactl awk sed grep tar gzip; do
            if have_cmd "$cmd"; then
                printf '%s=YES path=%s\n' "$cmd" "$(command -v "$cmd")"
            else
                printf '%s=NO\n' "$cmd"
            fi
        done
    } > "$OUTDIR/metadata.txt"
}

capture_irq_affinity() {
    outfile=$1
    {
        printf '# captured_at_utc=%s\n' "$(now_utc)"
        for irqdir in /proc/irq/[0-9]*; do
            [ -d "$irqdir" ] || continue
            irq=${irqdir##*/}
            printf 'IRQ=%s' "$irq"
            printf ' affinity_list='
            flatten_file "$irqdir/smp_affinity_list" | tr -d '\n'
            printf ' effective_affinity_list='
            flatten_file "$irqdir/effective_affinity_list" | tr -d '\n'
            printf ' affinity_mask='
            flatten_file "$irqdir/smp_affinity" | tr -d '\n'
            printf '\n'
        done
    } > "$outfile"
}

capture_queue_affinity() {
    outfile=$1
    {
        printf '# captured_at_utc=%s\n' "$(now_utc)"
        selected_interfaces | while IFS= read -r iface; do
            [ -d "/sys/class/net/$iface/queues" ] || continue
            printf '\n[interface=%s]\n' "$iface"
            for qdir in /sys/class/net/"$iface"/queues/rx-*; do
                [ -d "$qdir" ] || continue
                q=${qdir##*/}
                printf '%s rps_cpus=' "$q"
                flatten_file "$qdir/rps_cpus" | tr -d '\n'
                printf ' rps_flow_cnt='
                flatten_file "$qdir/rps_flow_cnt" | tr -d '\n'
                printf '\n'
            done
            for qdir in /sys/class/net/"$iface"/queues/tx-*; do
                [ -d "$qdir" ] || continue
                q=${qdir##*/}
                printf '%s xps_cpus=' "$q"
                flatten_file "$qdir/xps_cpus" | tr -d '\n'
                printf ' xps_rxqs='
                flatten_file "$qdir/xps_rxqs" | tr -d '\n'
                printf '\n'
            done
        done
    } > "$outfile"
}

capture_nic_context() {
    outdir=$1
    mkdir -p "$outdir" || return 1

    selected_interfaces | while IFS= read -r iface; do
        [ -e "/sys/class/net/$iface" ] || continue
        safe_iface=$(sanitize_name "$iface")
        idir="$outdir/$safe_iface"
        mkdir -p "$idir" || continue

        {
            printf 'interface=%s\n' "$iface"
            printf 'ifindex='; flatten_file "/sys/class/net/$iface/ifindex"
            printf 'operstate='; flatten_file "/sys/class/net/$iface/operstate"
            printf 'mtu='; flatten_file "/sys/class/net/$iface/mtu"
            printf 'address='; flatten_file "/sys/class/net/$iface/address"
            printf 'numa_node='; flatten_file "/sys/class/net/$iface/device/numa_node"
            printf 'local_cpulist='; flatten_file "/sys/class/net/$iface/device/local_cpulist"
            printf 'local_cpus='; flatten_file "/sys/class/net/$iface/device/local_cpus"
        } > "$idir/sysfs_identity.txt"

        if have_cmd ethtool; then
            ethtool -i "$iface" > "$idir/ethtool_driver.txt" 2>&1 || true
            ethtool -k "$iface" > "$idir/ethtool_features.txt" 2>&1 || true
            ethtool -l "$iface" > "$idir/ethtool_channels.txt" 2>&1 || true
            ethtool -x "$iface" > "$idir/ethtool_rss.txt" 2>&1 || true
            ethtool -g "$iface" > "$idir/ethtool_ring.txt" 2>&1 || true
            ethtool -c "$iface" > "$idir/ethtool_coalesce.txt" 2>&1 || true
        fi
    done
}

capture_global_context() {
    phase=$1
    outdir="$OUTDIR/context/$phase"

    safe_read /proc/interrupts > "$outdir/proc_interrupts.txt"
    safe_read /proc/softirqs > "$outdir/proc_softirqs.txt"
    safe_read /proc/net/softnet_stat > "$outdir/softnet_stat.txt"

    if have_cmd ip; then
        ip -details -statistics link show > "$outdir/ip_link_details.txt" 2>&1 || true
    else
        safe_read /proc/net/dev > "$outdir/proc_net_dev.txt"
    fi

    if have_cmd lscpu; then
        lscpu > "$outdir/lscpu.txt" 2>&1 || true
    fi

    if [ "$MODE" = detail ] || [ "$MODE" = full ]; then
        capture_irq_affinity "$outdir/irq_affinity.txt"
        capture_queue_affinity "$outdir/queue_affinity.txt"
        capture_nic_context "$outdir/nic"
    fi

    if [ "$MODE" = full ]; then
        safe_read /proc/sys/net/core/netdev_budget > "$outdir/netdev_budget.txt"
        safe_read /proc/sys/net/core/netdev_budget_usecs > "$outdir/netdev_budget_usecs.txt"
        safe_read /proc/sys/net/core/netdev_max_backlog > "$outdir/netdev_max_backlog.txt"
        safe_read /proc/sys/net/core/rps_sock_flow_entries > "$outdir/rps_sock_flow_entries.txt"
        safe_read /proc/sys/net/core/dev_weight > "$outdir/dev_weight.txt"
        safe_read /proc/sys/net/core/dev_weight_rx_bias > "$outdir/dev_weight_rx_bias.txt"
        safe_read /proc/sys/net/core/dev_weight_tx_bias > "$outdir/dev_weight_tx_bias.txt"
    fi
}

parse_softnet() {
    raw=$1
    parsed=$2
    epoch=$3
    utc=$4

    awk -v epoch="$epoch" -v utc="$utc" '
        function hexval(c, p) {
            c=tolower(c)
            p=index("0123456789abcdef", c)
            return p ? p-1 : 0
        }
        function hex2dec(s, i,n,v) {
            n=0
            for (i=1; i<=length(s); i++) {
                v=hexval(substr(s,i,1))
                n=n*16+v
            }
            return n
        }
        BEGIN {
            OFS="," 
            print "epoch","utc","cpu","processed","dropped","time_squeeze","cpu_collision","received_rps","flow_limit_count","field_count"
        }
        NF >= 3 {
            cpu=NR-1
            processed=hex2dec($1)
            dropped=hex2dec($2)
            squeeze=hex2dec($3)
            collision=(NF>=9 ? hex2dec($9) : 0)
            rps=(NF>=10 ? hex2dec($10) : 0)
            flow=(NF>=11 ? hex2dec($11) : 0)
            print epoch,utc,cpu,processed,dropped,squeeze,collision,rps,flow,NF
        }
    ' "$raw" > "$parsed"
}

append_softnet_delta() {
    current=$1
    current_epoch=$2

    [ -n "$PREV_PARSED" ] || return 0
    [ -r "$PREV_PARSED" ] || return 0
    [ -n "$PREV_EPOCH" ] || return 0

    elapsed=$((current_epoch - PREV_EPOCH))
    [ "$elapsed" -gt 0 ] || elapsed=$INTERVAL

    awk -F, -v OFS=, -v elapsed="$elapsed" '
        NR==FNR {
            if (FNR==1) next
            cpu=$3
            pp[cpu]=$4; pd[cpu]=$5; ps[cpu]=$6
            pc[cpu]=$7; pr[cpu]=$8; pf[cpu]=$9
            next
        }
        FNR==1 { next }
        {
            cpu=$3
            dp=$4-pp[cpu]
            dd=$5-pd[cpu]
            ds=$6-ps[cpu]
            dc=$7-pc[cpu]
            dr=$8-pr[cpu]
            df=$9-pf[cpu]

            reset=0
            if (!(cpu in pp) || dp<0 || dd<0 || ds<0 || dc<0 || dr<0 || df<0) {
                reset=1
                dp=dd=ds=dc=dr=df=0
            }

            printf "%s,%s,%s,%d,%d,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d\n", \
                $1,$2,cpu,dp,dd,ds,dc,dr,df, \
                dp/elapsed,dd/elapsed,ds/elapsed,dc/elapsed,dr/elapsed,df/elapsed,reset
        }
    ' "$PREV_PARSED" "$current" >> "$OUTDIR/summary/softnet_delta_rate.csv"
}

capture_interface_stats() {
    tickdir=$1

    if have_cmd ip; then
        ip -s link show > "$tickdir/ip_link_stats.txt" 2>&1 || true
    else
        safe_read /proc/net/dev > "$tickdir/proc_net_dev.txt"
    fi
}

capture_ethtool_stats() {
    tickdir=$1
    have_cmd ethtool || return 0

    mkdir -p "$tickdir/ethtool_stats" || return 0
    selected_interfaces | while IFS= read -r iface; do
        [ -e "/sys/class/net/$iface" ] || continue
        safe_iface=$(sanitize_name "$iface")
        ethtool -S "$iface" > "$tickdir/ethtool_stats/$safe_iface.txt" 2>&1 || true
    done
}

capture_qdisc_stats() {
    tickdir=$1
    have_cmd tc || return 0
    tc -s qdisc show > "$tickdir/tc_qdisc.txt" 2>&1 || true
}

capture_queue_sysfs() {
    tickdir=$1
    qout="$tickdir/queue_sysfs"
    mkdir -p "$qout" || return 0

    selected_interfaces | while IFS= read -r iface; do
        [ -d "/sys/class/net/$iface/queues" ] || continue
        safe_iface=$(sanitize_name "$iface")
        outfile="$qout/$safe_iface.txt"
        {
            printf '[interface=%s]\n' "$iface"
            for qdir in /sys/class/net/"$iface"/queues/*; do
                [ -d "$qdir" ] || continue
                q=${qdir##*/}
                printf '\n[queue=%s]\n' "$q"
                for f in "$qdir"/*; do
                    [ -f "$f" ] || continue
                    [ -r "$f" ] || continue
                    name=${f##*/}
                    case $name in
                        rps_cpus|rps_flow_cnt|xps_cpus|xps_rxqs|tx_maxrate|byte_queue_limits)
                            printf '%s=' "$name"
                            flatten_file "$f"
                            ;;
                    esac
                done
            done
        } > "$outfile"
    done
}

capture_nstat() {
    tickdir=$1
    have_cmd nstat || return 0
    nstat -az > "$tickdir/nstat.txt" 2>&1 || true
}

sample_once() {
    sample_id=$1
    epoch=$2
    elapsed="$3"
    utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    sid=$(printf '%06d' "$sample_id")
    tickdir="$OUTDIR/snapshots/snapshot_${sample_id}_elapsed_${elapsed}s"

    mkdir -p "$tickdir" || error_exit "failed to create sample directory: $tickdir"

    {
        printf 'sample_id=%s\n' "$sample_id"
        printf 'epoch=%s\n' "$epoch"
        printf 'utc=%s\n' "$utc"
    } > "$tickdir/sample_meta.txt"

    safe_read /proc/net/softnet_stat > "$tickdir/softnet_stat.raw"
    parse_softnet "$tickdir/softnet_stat.raw" "$tickdir/softnet_stat.csv" "$epoch" "$utc"
    safe_read /proc/softirqs > "$tickdir/proc_softirqs.txt"
    safe_read /proc/interrupts > "$tickdir/proc_interrupts.txt"
    capture_interface_stats "$tickdir"

    case $MODE in
        detail|full)
            capture_ethtool_stats "$tickdir"
            capture_qdisc_stats "$tickdir"
            ;;
    esac

    if [ "$MODE" = full ]; then
        capture_queue_sysfs "$tickdir"
        capture_nstat "$tickdir"
    fi

    append_softnet_delta "$tickdir/softnet_stat.csv" "$epoch"
    PREV_PARSED=$tickdir/softnet_stat.csv
    PREV_EPOCH=$epoch
}

write_summary_header() {
    cat > "$OUTDIR/summary/softnet_delta_rate.csv" <<'EOF_HEADER'
epoch,utc,cpu,processed_delta,dropped_delta,time_squeeze_delta,cpu_collision_delta,received_rps_delta,flow_limit_count_delta,processed_per_sec,dropped_per_sec,time_squeeze_per_sec,cpu_collision_per_sec,received_rps_per_sec,flow_limit_count_per_sec,counter_reset
EOF_HEADER
}

write_final_summary() {
    first=$(find "$OUTDIR/samples" -type f -name 'softnet_stat.csv' 2>/dev/null | sort | sed -n '1p')
    last=$(find "$OUTDIR/samples" -type f -name 'softnet_stat.csv' 2>/dev/null | sort | tail -n 1)

    {
        printf 'completed_at_utc=%s\n' "$(now_utc)"
        printf 'samples_collected=%s\n' "$SAMPLE_ID"
        printf 'duration_requested=%s\n' "$DURATION"
        printf 'interval_requested=%s\n' "$INTERVAL"
        printf 'mode=%s\n' "$MODE"
        printf 'first_parsed=%s\n' "${first:-none}"
        printf 'last_parsed=%s\n' "${last:-none}"
    } > "$OUTDIR/summary/collection_summary.txt"

    if [ -r "$OUTDIR/summary/softnet_delta_rate.csv" ]; then
        totals_tmp="$OUTDIR/summary/.softnet_cpu_totals.tmp"
        awk -F, '
            NR==1 { next }
            {
                cpu=$3
                p[cpu]+=$4; d[cpu]+=$5; s[cpu]+=$6
                c[cpu]+=$7; r[cpu]+=$8; f[cpu]+=$9
                if ($12+0 > maxs[cpu]) maxs[cpu]=$12+0
                if ($11+0 > maxd[cpu]) maxd[cpu]=$11+0
            }
            END {
                for (cpu in p)
                    printf "%s,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.3f,%.3f\n", cpu,p[cpu],d[cpu],s[cpu],c[cpu],r[cpu],f[cpu],maxd[cpu],maxs[cpu]
            }
        ' "$OUTDIR/summary/softnet_delta_rate.csv" | sort -t, -k1,1n > "$totals_tmp"
        {
            printf '%s\n' 'cpu,processed_delta_total,dropped_delta_total,time_squeeze_delta_total,cpu_collision_delta_total,received_rps_delta_total,flow_limit_count_delta_total,max_dropped_per_sec,max_time_squeeze_per_sec'
            cat "$totals_tmp"
        } > "$OUTDIR/summary/softnet_cpu_totals.csv"
        rm -f "$totals_tmp"
    fi
}

compress_output() {
    [ "$COMPRESS" -eq 1 ] || return 0
    have_cmd tar || { log 'WARNING: tar not available; compression skipped'; return 0; }
    have_cmd gzip || { log 'WARNING: gzip not available; compression skipped'; return 0; }

    parent=$(dirname "$OUTDIR")
    base=$(basename "$OUTDIR")
    archive="$OUTDIR.tar.gz"
    tar -C "$parent" -czf "$archive" "$base" 2>/dev/null || {
        log 'WARNING: failed to create archive'
        return 0
    }
    log "INFO: archive created: $archive"
}

cleanup_signal() {
    sig=$1
    log "WARNING: interrupted by $sig"
    if [ -n "$OUTDIR" ] && [ -d "$OUTDIR" ]; then
        capture_global_context end 2>/dev/null || true
        write_final_summary 2>/dev/null || true
        {
            printf 'status=interrupted\n'
            printf 'signal=%s\n' "$sig"
            printf 'ended_at_utc=%s\n' "$(now_utc)"
            printf 'samples_collected=%s\n' "$SAMPLE_ID"
        } > "$OUTDIR/completed.txt"
    fi
    exit 130
}

main() {
    parse_args "$@"
    validate_args
    validate_interfaces
    prepare_dirs
    save_metadata
    write_summary_header

    START_EPOCH=$(now_epoch)
    END_EPOCH=$((START_EPOCH + DURATION))

    trap 'cleanup_signal INT' INT
    trap 'cleanup_signal TERM' TERM
    trap 'cleanup_signal HUP' HUP

    capture_global_context start

    log "INFO: output directory = $OUTDIR"
    log "INFO: duration=$DURATION interval=$INTERVAL mode=$MODE"
    log "INFO: interfaces=${IFACES:-auto_all_non_loopback}"

    while :; do
        now=$(now_epoch)
        [ "$now" -ge "$END_EPOCH" ] && break

        SAMPLE_ID=$((SAMPLE_ID + 1))
        sample_once "$sample_id" "$now" "$elapsed"

        now=$(now_epoch)
        [ "$now" -ge "$END_EPOCH" ] && break

        remaining=$((END_EPOCH - now))
        sleep_for=$INTERVAL
        [ "$remaining" -lt "$sleep_for" ] && sleep_for=$remaining
        [ "$sleep_for" -gt 0 ] && sleep "$sleep_for"
    done

    capture_global_context end
    write_final_summary

    {
        printf 'status=completed\n'
        printf 'started_epoch=%s\n' "$START_EPOCH"
        printf 'ended_epoch=%s\n' "$(now_epoch)"
        printf 'ended_at_utc=%s\n' "$(now_utc)"
        printf 'samples_collected=%s\n' "$SAMPLE_ID"
    } > "$OUTDIR/completed.txt"

    compress_output
    log "INFO: collection completed: $OUTDIR"
}

main "$@"
