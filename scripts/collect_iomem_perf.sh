#!/usr/bin/env bash
# collect_iomem_perf.sh
#
# /proc/iomem-oriented performance/evidence collector.
#
# Purpose:
#   - Collect timestamped /proc/iomem snapshots for physical address/resource map analysis.
#   - Preserve raw snapshots, parsed summaries, before/after diffs, and related firmware/kernel context.
#   - Support duration/interval based collection similar to other perf collectors.
#
# Default:
#   - 10 minutes total duration
#   - 60 seconds interval
#   - About 10 snapshots
#
# Supported targets:
#   Ubuntu 22.04/24.04, Debian 11/12, Oracle Linux, RHEL 8/9, SLES 12 SP5/15 SP6
#
# Notes:
#   - /proc/iomem may redact physical addresses as 00000000-00000000 depending on
#     kernel/security settings and privileges. Run as root for best evidence.
#   - This script is read-only. It does not change kernel parameters or security settings.
#   - GitHub Actions artifact upload rejects some path characters such as ':'.
#     Therefore PCI BDF directory names are sanitized and original BDF values are
#     preserved in original_pci_bdf.txt.
#
# Modes:
#   basic  : /proc/iomem raw snapshots + selected resource summary + first/last diff
#   detail : basic + /proc/ioports, /sys/firmware/memmap, dmesg/journal resource clues
#   full   : detail + module/device/resource context from /sys and lspci if available
#
# Examples:
#   sudo ./collect_iomem_perf.sh -o /var/tmp/iomem_bundle
#   sudo ./collect_iomem_perf.sh -d 600 -i 60 -m detail -o /var/tmp/iomem_detail
#   sudo ./collect_iomem_perf.sh -d 1800 -i 300 -m full --compress -o /var/tmp/iomem_full
#

set -u
umask 077
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

DURATION=600
INTERVAL=60
MODE="basic"
OUTDIR=""
COMPRESS=0
SCRIPT_NAME=$(basename "$0")
START_EPOCH=""

usage() {
    cat <<'EOF'
Usage:
  collect_iomem_perf.sh [options]

Options:
  -o DIR      Output directory. Default: ./iomem_bundle_YYYYmmdd_HHMMSS
  -d SEC      Total collection duration in seconds. Default: 600
  -i SEC      Collection interval in seconds. Default: 60
  -m MODE     Collection mode: basic, detail, full. Default: basic
  --compress  Create tar.gz archive at the end if tar/gzip are available.
  -h, --help  Show this help.

Modes:
  basic:
    - /proc/iomem raw snapshots every interval
    - selected resource summary per snapshot
    - first/last diff

  detail:
    - basic
    - /proc/ioports
    - /sys/firmware/memmap, if present
    - dmesg/journal excerpts for ACPI/PCI/e820/resource/IOMMU/MMIO clues

  full:
    - detail
    - /sys/devices resource files
    - /sys/bus/pci/devices/*/resource
    - lspci evidence if available

Resource categories commonly useful:
  - System RAM
  - reserved
  - ACPI Tables / ACPI Non-volatile Storage
  - PCI Bus / PCI MMCONFIG / PCI host bridge windows
  - Kernel code/data/bss/rodata
  - Crash kernel
  - Persistent Memory
  - CXL / iomem_resource-like platform resources

Important:
  /proc/iomem is not a high-frequency performance counter. It is mostly static.
  The interval collection is meant to correlate resource-map evidence with an incident window.
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

safe_read() {
    local path="$1"
    if [ -r "$path" ]; then
        cat "$path" 2>/dev/null || true
    else
        echo "UNREADABLE_OR_NOT_PRESENT"
    fi
}

# Sanitize path components for GitHub Actions artifact compatibility.
# Linux allows ':' in file names, but artifact upload rejects characters
# that can break downloads on filesystems such as NTFS.
sanitize_artifact_name() {
    printf '%s' "$1" | sed 's/["*:<>?|\\]/_/g; s/[[:space:]]/_/g'
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o)
                [ "$#" -ge 2 ] || error_exit "-o requires directory"
                OUTDIR=$2; shift 2 ;;
            -d)
                [ "$#" -ge 2 ] || error_exit "-d requires seconds"
                DURATION=$2; shift 2 ;;
            -i)
                [ "$#" -ge 2 ] || error_exit "-i requires seconds"
                INTERVAL=$2; shift 2 ;;
            -m)
                [ "$#" -ge 2 ] || error_exit "-m requires mode"
                MODE=$2; shift 2 ;;
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
    [ "$DURATION" -gt 0 ] || error_exit "duration must be > 0"
    [ "$INTERVAL" -gt 0 ] || error_exit "interval must be > 0"

    case "$MODE" in
        basic|detail|full) : ;;
        *) error_exit "invalid mode: $MODE" ;;
    esac

    [ -r /proc/iomem ] || error_exit "/proc/iomem is not readable"

    if [ -z "$OUTDIR" ]; then
        OUTDIR="./iomem_bundle_$(date +%Y%m%d_%H%M%S)"
    fi
}

preflight_dirs() {
    mkdir -p "$OUTDIR" "$OUTDIR/raw" "$OUTDIR/summary" "$OUTDIR/snapshots" "$OUTDIR/static" || \
        error_exit "failed to create output directory: $OUTDIR"
}

save_metadata() {
    local meta="$OUTDIR/00_metadata.txt"
    {
        echo "script=$SCRIPT_NAME"
        echo "started_at_utc=$(now_utc)"
        echo "started_at_epoch=$(now_epoch)"
        echo "duration=$DURATION"
        echo "interval=$INTERVAL"
        echo "mode=$MODE"
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
        echo "[identity]"
        id 2>/dev/null || true
        echo
        echo "[cmdline]"
        safe_read /proc/cmdline
        echo
        echo "[security hint]"
        echo "/proc/iomem may redact addresses depending on kernel/security settings and privileges."
        echo
        echo "[artifact compatibility]"
        echo "PCI BDF directory names are sanitized for GitHub Actions artifact upload."
        echo "Original PCI BDF values are preserved in original_pci_bdf.txt."
        echo
        echo "[available commands]"
        for c in awk sed grep diff sort uniq wc dmesg journalctl lspci find tar gzip; do
            if have_cmd "$c"; then
                echo "$c=YES ($(command -v "$c"))"
            else
                echo "$c=NO"
            fi
        done
        echo
        echo "[important files]"
        for f in /proc/iomem /proc/ioports /proc/cmdline /sys/firmware/memmap /sys/firmware/efi; do
            if [ -e "$f" ]; then
                ls -ld "$f" 2>/dev/null || true
            else
                echo "$f=NOT_PRESENT"
            fi
        done
    } > "$meta"
}

capture_static_context() {
    {
        echo "[mounts]"
        safe_read /proc/mounts
        echo
        echo "[meminfo selected]"
        grep -E '^(MemTotal|MemFree|MemAvailable|Reserved|CmaTotal|CmaFree|HugePages_Total|HugePages_Free|Hugepagesize):' /proc/meminfo 2>/dev/null || true
        echo
        echo "[cpu online]"
        safe_read /sys/devices/system/cpu/online
        echo
        echo "[memory block size]"
        safe_read /sys/devices/system/memory/block_size_bytes
        echo
        echo "[online memory blocks summary]"
        if [ -d /sys/devices/system/memory ]; then
            find /sys/devices/system/memory -maxdepth 1 -name 'memory*' -type d 2>/dev/null | wc -l
        fi
    } > "$OUTDIR/static/system_context.txt"
}

summarize_iomem() {
    local src="$1"
    local dst="$2"
    awk '
    BEGIN {
      printf "%-36s %10s %s\n", "resource", "count", "examples"
      printf "%-36s %10s %s\n", "------------------------------------", "----------", "--------"
    }
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^[0-9a-fA-F]+-[0-9a-fA-F]+[[:space:]]*:/) {
        desc=line
        sub(/^[0-9a-fA-F]+-[0-9a-fA-F]+[[:space:]]*:[[:space:]]*/, "", desc)
        count[desc]++
        if (!(desc in example)) example[desc]=line
      }
    }
    END {
      for (d in count) {
        printf "%-36s %10d %s\n", d, count[d], example[d]
      }
    }
    ' "$src" | sort > "$dst" 2>&1 || true
}

extract_iomem_focus() {
    local src="$1"
    local dst="$2"
    {
        echo "[System RAM / reserved / ACPI / PCI / kernel / crash / persistent memory focus]"
        grep -Ei 'System RAM|reserved|ACPI|PCI|MMCONFIG|Kernel|Crash kernel|Persistent|CXL|IOMMU|IOAPIC|Local APIC|Video ROM|BIOS' "$src" 2>/dev/null || true
    } > "$dst"
}

collect_firmware_memmap() {
    local dst="$1"
    mkdir -p "$dst"

    if [ -d /sys/firmware/memmap ]; then
        {
            echo "# source: /sys/firmware/memmap"
            echo "# collected_at_epoch: $(now_epoch)"
            echo
            printf '%-8s %-18s %-18s %s\n' 'index' 'start' 'end' 'type'
            printf '%-8s %-18s %-18s %s\n' '--------' '------------------' '------------------' '----------------'
            for e in /sys/firmware/memmap/*; do
                [ -d "$e" ] || continue
                idx=$(basename "$e")
                case "$idx" in *[!0-9]*|'') continue ;; esac
                start=$(safe_read "$e/start" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
                end=$(safe_read "$e/end" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
                type=$(safe_read "$e/type" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
                printf '%-8s %-18s %-18s %s\n' "$idx" "$start" "$end" "$type"
            done | sort -n
        } > "$dst/firmware_memmap.txt" 2>&1 || true
    else
        echo "/sys/firmware/memmap not present" > "$dst/firmware_memmap.txt"
    fi
}

collect_ioports() {
    local dst="$1"
    if [ -r /proc/ioports ]; then
        cat /proc/ioports > "$dst/ioports.txt" 2>/dev/null || true
    else
        echo "/proc/ioports not readable" > "$dst/ioports.txt"
    fi
}

collect_logs() {
    local dst="$1"
    mkdir -p "$dst"
    dmesg > "$dst/dmesg_raw_tail.txt" 2>&1 || true
    dmesg 2>/dev/null | grep -Ei 'e820|efi|iomem|resource|reserved|ACPI|PCI|MMCONFIG|IOMMU|DMAR|AMD-Vi|BAR|memblock|crashkernel|CXL' | tail -n 500 > "$dst/dmesg_iomem_resource_tail.txt" 2>&1 || true
    if have_cmd journalctl; then
        journalctl -k --no-pager -n 1000 > "$dst/journal_kernel_tail.txt" 2>&1 || true
        journalctl -k --no-pager -n 2000 2>/dev/null | grep -Ei 'e820|efi|iomem|resource|reserved|ACPI|PCI|MMCONFIG|IOMMU|DMAR|AMD-Vi|BAR|memblock|crashkernel|CXL' > "$dst/journal_iomem_resource_tail.txt" 2>&1 || true
    fi
}

collect_sys_resources_full() {
    local dst="$1"
    mkdir -p "$dst"

    if [ -d /sys/bus/pci/devices ]; then
        mkdir -p "$dst/pci_resources"

        for dev in /sys/bus/pci/devices/*; do
            [ -d "$dev" ] || continue

            raw_name=$(basename "$dev")
            name=$(sanitize_artifact_name "$raw_name")

            mkdir -p "$dst/pci_resources/$name"

            # Preserve original PCI BDF because ':' is replaced for artifact compatibility.
            echo "$raw_name" > "$dst/pci_resources/$name/original_pci_bdf.txt"

            for f in resource resource0 resource1 resource2 resource3 resource4 resource5 vendor device class numa_node; do
                [ -e "$dev/$f" ] || continue
                if [ -r "$dev/$f" ] && [ ! -d "$dev/$f" ]; then
                    cat "$dev/$f" > "$dst/pci_resources/$name/$f.txt" 2>/dev/null || true
                fi
            done
        done
    fi

    if have_cmd lspci; then
        lspci -vvv > "$dst/lspci_vvv.txt" 2>&1 || true
        lspci -Dnn > "$dst/lspci_Dnn.txt" 2>&1 || true
    fi

    if [ -d /sys/devices/system/memory ]; then
        find /sys/devices/system/memory -maxdepth 2 -type f \( -name state -o -name phys_index -o -name removable -o -name valid_zones \) -print 2>/dev/null | while IFS= read -r f; do
            rel=${f#/sys/devices/system/memory/}
            mkdir -p "$dst/memory_blocks/$(dirname "$rel")" 2>/dev/null || true
            cat "$f" > "$dst/memory_blocks/$rel.txt" 2>/dev/null || true
        done
    fi
}

collect_snapshot() {
    local sample_id="$1"
    local elapsed="$2"
    local dir="$OUTDIR/snapshots/sample_${sample_id}_elapsed_${elapsed}s"
    mkdir -p "$dir" "$dir/summary" "$dir/logs" "$dir/proc" || return 0

    {
        echo "sample_id=$sample_id"
        echo "elapsed=$elapsed"
        echo "timestamp_utc=$(now_utc)"
        echo "timestamp_epoch=$(now_epoch)"
        echo "mode=$MODE"
    } > "$dir/sample_meta.txt"

    cat /proc/iomem > "$dir/proc/iomem.txt" 2>/dev/null || true
    cp "$dir/proc/iomem.txt" "$OUTDIR/raw/iomem_sample_${sample_id}_elapsed_${elapsed}s.txt" 2>/dev/null || true

    summarize_iomem "$dir/proc/iomem.txt" "$dir/summary/iomem_resource_summary.txt"
    extract_iomem_focus "$dir/proc/iomem.txt" "$dir/summary/iomem_focus.txt"

    if [ "$MODE" = "detail" ] || [ "$MODE" = "full" ]; then
        collect_ioports "$dir/proc"
        collect_firmware_memmap "$dir/proc"
        collect_logs "$dir/logs"
    fi

    if [ "$MODE" = "full" ]; then
        collect_sys_resources_full "$dir/sys_resources"
    fi
}

write_diff_summary() {
    first=$(ls "$OUTDIR"/raw/iomem_sample_* 2>/dev/null | head -n 1 || true)
    last=$(ls "$OUTDIR"/raw/iomem_sample_* 2>/dev/null | tail -n 1 || true)

    {
        echo "[first sample]"
        echo "${first:-not_found}"
        echo
        echo "[last sample]"
        echo "${last:-not_found}"
        echo
        echo "[diff first vs last]"
        if [ -n "$first" ] && [ -n "$last" ]; then
            if have_cmd diff; then
                diff -u "$first" "$last" || true
            else
                echo "diff not available"
            fi
        else
            echo "not enough samples"
        fi
    } > "$OUTDIR/summary/iomem_first_last_diff.txt"

    if [ -n "$first" ]; then
        summarize_iomem "$first" "$OUTDIR/summary/iomem_first_resource_summary.txt"
        extract_iomem_focus "$first" "$OUTDIR/summary/iomem_first_focus.txt"
    fi
    if [ -n "$last" ]; then
        summarize_iomem "$last" "$OUTDIR/summary/iomem_last_resource_summary.txt"
        extract_iomem_focus "$last" "$OUTDIR/summary/iomem_last_focus.txt"
    fi

    {
        echo "[iomem first resource summary]"
        cat "$OUTDIR/summary/iomem_first_resource_summary.txt" 2>/dev/null || true
        echo
        echo "[iomem last resource summary]"
        cat "$OUTDIR/summary/iomem_last_resource_summary.txt" 2>/dev/null || true
        echo
        echo "[iomem focus]"
        cat "$OUTDIR/summary/iomem_last_focus.txt" 2>/dev/null || true
        echo
        echo "[redaction check]"
        if [ -n "$last" ]; then
            zero_count=$(grep -c '00000000-00000000' "$last" 2>/dev/null || echo 0)
            echo "zero_address_lines=$zero_count"
            if [ "$zero_count" -gt 0 ]; then
                echo "NOTE: /proc/iomem appears to contain redacted zero address ranges. Run as root and check kernel/security policy if full addresses are required."
            fi
        fi
    } > "$OUTDIR/summary/00_summary.txt"
}

compress_output() {
    [ "$COMPRESS" -eq 1 ] || return 0
    have_cmd tar || { log "WARN: tar not available; skip compression"; return 0; }
    have_cmd gzip || { log "WARN: gzip not available; skip compression"; return 0; }

    local parent base archive
    parent=$(dirname "$OUTDIR")
    base=$(basename "$OUTDIR")
    archive="${OUTDIR}.tar.gz"
    (cd "$parent" && tar -czf "$archive" "$base") 2>/dev/null || log "WARN: compression failed"
}

main() {
    parse_args "$@"
    validate_args
    preflight_dirs
    START_EPOCH=$(now_epoch)
    end_epoch=$((START_EPOCH + DURATION))

    save_metadata
    capture_static_context

    log "INFO: output directory: $OUTDIR"
    log "INFO: mode=$MODE duration=$DURATION interval=$INTERVAL"

    sample_id=0
    while :; do
        now=$(now_epoch)
        [ "$now" -ge "$end_epoch" ] && break
        elapsed=$((now - START_EPOCH))
        sample_id=$((sample_id + 1))
        collect_snapshot "$sample_id" "$elapsed"
        sleep "$INTERVAL"
    done

    write_diff_summary

    {
        echo "completed_at_utc=$(now_utc)"
        echo "completed_at_epoch=$(now_epoch)"
        echo "samples_collected=$sample_id"
    } > "$OUTDIR/99_collection_end.txt"

    compress_output
    log "INFO: completed: $OUTDIR"
}

main "$@"
