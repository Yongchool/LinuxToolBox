#!/usr/bin/env sh

# collect_firmware_memmap.sh
#
# Collect /sys/firmware/memmap entries in numeric index order.
# Compatible target environments:
#   - Ubuntu 22.04 / 24.04
#   - Debian 11 / 12
#   - Oracle Linux
#   - Red Hat Enterprise Linux 8 / 9
#   - SUSE Linux Enterprise Server 12 SP5 / 15 SP6
#
# Usage:
#   ./collect_firmware_memmap.sh OUTPUT_FILE
#
# Example:
#   ./collect_firmware_memmap.sh /var/log/firmware_memmap.out
#
# Notes:
#   - Reads Linux sysfs data from /sys/firmware/memmap
#   - Saves output atomically via temporary file + rename
#   - Uses only POSIX / widely available userland utilities
#   - Designed to be safe on minimal enterprise Linux images

LC_ALL=C
export LC_ALL

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

usage() {
    echo "Usage: $0 OUTPUT_FILE" >&2
}

error_exit() {
    echo "ERROR: $*" >&2
    exit 1
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

read_one_line() {
    file=$1

    if [ ! -r "$file" ]; then
        printf '%s' 'UNREADABLE'
        return 0
    fi

    # Flatten possible multiline content defensively.
    tr '\n' ' ' < "$file" | sed 's/[[:space:]]*$//'
}

safe_dirname() {
    target=$1

    if have_cmd dirname; then
        dirname -- "$target" 2>/dev/null || dirname "$target"
        return $?
    fi

    case "$target" in
        */*) printf '%s\n' "${target%/*}" ;;
        *)   printf '.\n' ;;
    esac
}

safe_basename() {
    target=$1

    if have_cmd basename; then
        basename -- "$target" 2>/dev/null || basename "$target"
        return $?
    fi

    case "$target" in
        */) target=${target%/} ;;
    esac
    printf '%s\n' "${target##*/}"
}

# Validate required commands early.
for cmd in tr sed sort date mv rm printf; do
    have_cmd "$cmd" || error_exit "required command not found: $cmd"
done

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

out_file=$1
memmap_dir=/sys/firmware/memmap

# Condition 1: memmap path missing -> print message and exit immediately
if [ ! -d "$memmap_dir" ]; then
    echo "ERROR: $memmap_dir does not exist" >&2
    exit 1
fi

out_dir=$(safe_dirname "$out_file")

if [ ! -d "$out_dir" ]; then
    error_exit "output directory does not exist: $out_dir"
fi

if [ ! -w "$out_dir" ]; then
    error_exit "output directory is not writable: $out_dir"
fi

# Prefer mktemp when available; otherwise fall back to PID-based names.
if have_cmd mktemp; then
    tmp_file=$(mktemp "${out_file}.tmp.XXXXXX") || error_exit "failed to create temporary file"
    idx_file=$(mktemp "${out_file}.idx.XXXXXX") || {
        rm -f "$tmp_file"
        error_exit "failed to create temporary index file"
    }
else
    tmp_file="${out_file}.$$"
    idx_file="${tmp_file}.idx"
    : > "$tmp_file" || error_exit "failed to create temporary file: $tmp_file"
    : > "$idx_file" || {
        rm -f "$tmp_file"
        error_exit "failed to create temporary index file: $idx_file"
    }
fi

cleanup() {
    rm -f "$tmp_file" "$idx_file"
}
trap cleanup EXIT HUP INT TERM

# Build numeric index list at collection time.
# This avoids shell glob order such as 0, 1, 10, 11, 2, 3...
idx_count=0
: > "$idx_file"

for entry in "$memmap_dir"/*; do
    if [ ! -d "$entry" ]; then
        continue
    fi

    index=$(safe_basename "$entry")

    case "$index" in
        *[!0-9]*|'')
            continue
            ;;
    esac

    printf '%s\n' "$index" >> "$idx_file"
    idx_count=$((idx_count + 1))
done

sort -n "$idx_file" -o "$idx_file"

# Condition 2: no numeric entries found -> print message and exit immediately
if [ "$idx_count" -eq 0 ]; then
    echo "ERROR: no numeric entries found under $memmap_dir" >&2
    exit 1
fi

# Generate output into a temporary file first for atomic replacement.
{
    echo "# source: /sys/firmware/memmap"
    echo "# format: index start end type"
    echo "# collected_at_epoch: $(date +%s)"
    echo

    printf '%-8s %-18s %-18s %s\n' 'index' 'start' 'end' 'type'
    printf '%-8s %-18s %-18s %s\n' '--------' '------------------' '------------------' '----------------'

    while IFS= read -r index; do
        entry="$memmap_dir/$index"

        start=$(read_one_line "$entry/start")
        end=$(read_one_line "$entry/end")
        type=$(read_one_line "$entry/type")

        printf '%-8s %-18s %-18s %s\n' "$index" "$start" "$end" "$type"
    done < "$idx_file"
} > "$tmp_file" || error_exit 'failed to collect firmware memmap'

mv "$tmp_file" "$out_file" || error_exit "failed to write output file: $out_file"
rm -f "$idx_file"
trap - EXIT HUP INT TERM

exit 0
