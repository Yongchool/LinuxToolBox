#!/bin/sh

# collect_firmware_memmap.sh
# Collect /sys/firmware/memmap entries in numeric index order.
# Usage: ./collect_firmware_memmap.sh OUTPUT_FILE

LC_ALL=C
export LC_ALL

usage() {
    echo "Usage: $0 OUTPUT_FILE" >&2
}

read_one_line() {
    file=$1

    if [ ! -r "$file" ]; then
        printf '%s' "UNREADABLE"
        return 0
    fi

    # Flatten possible multiline content defensively.
    tr '\n' ' ' < "$file" | sed 's/[[:space:]]*$//'
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

out_file=$1
memmap_dir=/sys/firmware/memmap

if [ ! -d "$memmap_dir" ]; then
    echo "ERROR: $memmap_dir does not exist" >&2
    exit 1
fi

out_dir=$(dirname "$out_file")

if [ ! -d "$out_dir" ]; then
    echo "ERROR: output directory does not exist: $out_dir" >&2
    exit 1
fi

if [ ! -w "$out_dir" ]; then
    echo "ERROR: output directory is not writable: $out_dir" >&2
    exit 1
fi

tmp_file="${out_file}.$$"
idx_file="${tmp_file}.idx"

rm -f "$tmp_file" "$idx_file"

# Build numeric index list at collection time.
# This avoids shell glob ordering such as: 0 1 10 11 2 3 ...
for entry in "$memmap_dir"/*; do
    [ -d "$entry" ] || continue

    index=$(basename "$entry")

    case "$index" in
        *[!0-9]*|'')
            # Skip unexpected non-numeric entries defensively.
            continue
            ;;
    esac

    printf '%s\n' "$index"
done | sort -n > "$idx_file"

if [ ! -s "$idx_file" ]; then
    rm -f "$tmp_file" "$idx_file"
    echo "ERROR: no numeric entries found under $memmap_dir" >&2
    exit 1
fi

{
    echo "# source: /sys/firmware/memmap"
    echo "# format: index start end type"
    echo "# collected_at_epoch: $(date +%s)"
    echo

    printf "%-8s %-18s %-18s %s\n" "index" "start" "end" "type"
    printf "%-8s %-18s %-18s %s\n" "--------" "------------------" "------------------" "----------------"

    while IFS= read -r index; do
        entry="$memmap_dir/$index"

        start=$(read_one_line "$entry/start")
        end=$(read_one_line "$entry/end")
        type=$(read_one_line "$entry/type")

        printf "%-8s %-18s %-18s %s\n" "$index" "$start" "$end" "$type"
    done < "$idx_file"
} > "$tmp_file"

if [ "$?" -ne 0 ]; then
    rm -f "$tmp_file" "$idx_file"
    echo "ERROR: failed to collect firmware memmap" >&2
    exit 1
fi

mv "$tmp_file" "$out_file" || {
    rm -f "$tmp_file" "$idx_file"
    echo "ERROR: failed to write output file: $out_file" >&2
    exit 1
}

rm -f "$idx_file"
exit 0