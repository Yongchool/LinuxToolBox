#!/bin/sh
#
# enable_lockup_panic_for_kdump.sh
#
# Purpose:
#   Prepare the running kernel so that:
#     - soft lockup detection is active
#     - hung task detection is active
#     - soft lockup triggers kernel panic
#     - hung task detection triggers kernel panic
#   This is intended for systems where kdump is already configured.
#
# Runtime-only changes:
#   This script writes only to /proc/sys/kernel/*.
#   It does NOT modify /etc/sysctl.conf, /etc/sysctl.d/*, GRUB, or bootloader files.
#   Therefore these changes do not persist by this script itself.
#   After reboot, values are re-established by the system's normal boot/sysctl policy.
#
# Recommended diagnostic values used here:
#   kernel.watchdog=1
#   kernel.soft_watchdog=1
#   kernel.watchdog_thresh=10
#     -> soft lockup threshold is approximately 2 * watchdog_thresh (~20 sec)
#
#   kernel.hung_task_timeout_secs=40
#   kernel.hung_task_panic=1
#
#   kernel.softlockup_panic=1
#
# No arguments are required.
#

LC_ALL=C
export LC_ALL

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_NAME=${0##*/}

WATCHDOG_THRESH=10
HUNG_TASK_TIMEOUT=40

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    uid=$(id -u 2>/dev/null || printf '%s' unknown)
    [ "$uid" = "0" ] || die "Run this script as root."
}

read_value() {
    path=$1
    if [ -r "$path" ]; then
        cat "$path" 2>/dev/null
    else
        printf '%s\n' "UNAVAILABLE"
    fi
}

require_writable() {
    path=$1
    desc=$2

    [ -e "$path" ] || die "$desc is unavailable: $path"
    [ -w "$path" ] || die "$desc is not writable: $path"
}

show_value() {
    name=$1
    path=$2
    printf '  %-34s %s\n' "$name" "$(read_value "$path")"
}

set_value() {
    name=$1
    path=$2
    value=$3

    require_writable "$path" "$name"

    if printf '%s\n' "$value" > "$path" 2>/dev/null; then
        printf '  SET %-30s %s\n' "$name" "$value"
    else
        die "Failed to set $name=$value"
    fi
}

check_kdump() {
    log ""
    log "=== Crash dump readiness ==="

    if [ -r /sys/kernel/kexec_crash_loaded ]; then
        crash_loaded=$(cat /sys/kernel/kexec_crash_loaded 2>/dev/null || printf 'unknown')
        printf '  %-34s %s\n' "kexec_crash_loaded" "$crash_loaded"

        if [ "$crash_loaded" != "1" ]; then
            log ""
            log "WARNING:"
            log "  kdump crash kernel does not appear to be loaded."
            log "  Panic may occur without producing a vmcore."
        fi
    else
        printf '  %-34s %s\n' "kexec_crash_loaded" "UNAVAILABLE"
        log "  WARNING: Unable to verify whether a crash kernel is loaded."
    fi

    if grep -q 'crashkernel=' /proc/cmdline 2>/dev/null; then
        printf '  %-34s %s\n' "crashkernel parameter" "present"
    else
        printf '  %-34s %s\n' "crashkernel parameter" "not found"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet kdump 2>/dev/null; then
            printf '  %-34s %s\n' "kdump service" "active"
        elif systemctl is-active --quiet kdump-tools 2>/dev/null; then
            printf '  %-34s %s\n' "kdump-tools service" "active"
        else
            printf '  %-34s %s\n' "kdump service" "not confirmed active"
        fi
    fi
}

show_current() {
    log ""
    log "=== Current kernel values ==="

    show_value "kernel.watchdog" /proc/sys/kernel/watchdog
    show_value "kernel.soft_watchdog" /proc/sys/kernel/soft_watchdog
    show_value "kernel.watchdog_thresh" /proc/sys/kernel/watchdog_thresh
    show_value "kernel.softlockup_panic" /proc/sys/kernel/softlockup_panic
    show_value "kernel.hung_task_timeout_secs" /proc/sys/kernel/hung_task_timeout_secs
    show_value "kernel.hung_task_panic" /proc/sys/kernel/hung_task_panic

    if [ -e /proc/sys/kernel/nmi_watchdog ]; then
        show_value "kernel.nmi_watchdog" /proc/sys/kernel/nmi_watchdog
    fi

    if [ -e /proc/sys/kernel/hardlockup_panic ]; then
        show_value "kernel.hardlockup_panic" /proc/sys/kernel/hardlockup_panic
    fi
}

show_planned() {
    log ""
    log "=== Values to be applied ==="
    printf '  %-34s %s\n' "kernel.watchdog" "1"
    printf '  %-34s %s\n' "kernel.soft_watchdog" "1"
    printf '  %-34s %s\n' "kernel.watchdog_thresh" "$WATCHDOG_THRESH"
    printf '  %-34s %s\n' "kernel.softlockup_panic" "1"
    printf '  %-34s %s\n' "kernel.hung_task_timeout_secs" "$HUNG_TASK_TIMEOUT"
    printf '  %-34s %s\n' "kernel.hung_task_panic" "1"

    log ""
    log "Expected behavior:"
    log "  soft lockup detection threshold : approximately $((WATCHDOG_THRESH * 2)) seconds"
    log "  hung task detection threshold   : ${HUNG_TASK_TIMEOUT} seconds"
    log "  soft lockup -> kernel panic      : enabled"
    log "  hung task   -> kernel panic      : enabled"
}

apply_settings() {
    log ""
    log "=== Applying runtime kernel values ==="

    set_value "kernel.watchdog" \
        /proc/sys/kernel/watchdog \
        1

    set_value "kernel.soft_watchdog" \
        /proc/sys/kernel/soft_watchdog \
        1

    set_value "kernel.watchdog_thresh" \
        /proc/sys/kernel/watchdog_thresh \
        "$WATCHDOG_THRESH"

    set_value "kernel.softlockup_panic" \
        /proc/sys/kernel/softlockup_panic \
        1

    set_value "kernel.hung_task_timeout_secs" \
        /proc/sys/kernel/hung_task_timeout_secs \
        "$HUNG_TASK_TIMEOUT"

    set_value "kernel.hung_task_panic" \
        /proc/sys/kernel/hung_task_panic \
        1
}

verify_settings() {
    log ""
    log "=== Verification ==="

    failed=0

    verify_one() {
        name=$1
        path=$2
        expected=$3
        actual=$(read_value "$path")

        if [ "$actual" = "$expected" ]; then
            printf '  OK  %-30s %s\n' "$name" "$actual"
        else
            printf '  FAIL %-30s expected=%s actual=%s\n' \
                "$name" "$expected" "$actual"
            failed=1
        fi
    }

    verify_one "kernel.watchdog" \
        /proc/sys/kernel/watchdog \
        1

    verify_one "kernel.soft_watchdog" \
        /proc/sys/kernel/soft_watchdog \
        1

    verify_one "kernel.watchdog_thresh" \
        /proc/sys/kernel/watchdog_thresh \
        "$WATCHDOG_THRESH"

    verify_one "kernel.softlockup_panic" \
        /proc/sys/kernel/softlockup_panic \
        1

    verify_one "kernel.hung_task_timeout_secs" \
        /proc/sys/kernel/hung_task_timeout_secs \
        "$HUNG_TASK_TIMEOUT"

    verify_one "kernel.hung_task_panic" \
        /proc/sys/kernel/hung_task_panic \
        1

    [ "$failed" -eq 0 ] || die "One or more kernel values could not be verified."
}

main() {
    require_root

    log "$SCRIPT_NAME"
    log "Configure soft-lockup and hung-task panic for kdump/vmcore collection."

    check_kdump
    show_current
    show_planned
    apply_settings
    verify_settings

    log ""
    log "=== Completed ==="
    log "The running kernel is now configured to panic on:"
    log "  - soft lockup"
    log "  - hung task"
    log ""
    log "These changes were made only through /proc/sys and this script does not"
    log "write persistent sysctl or boot configuration."
    log ""
    log "After reboot, the kernel values will be restored according to the system's"
    log "normal boot/sysctl configuration."
    log ""
    log "IMPORTANT:"
    log "  A detected soft lockup or hung task can now intentionally panic the host."
    log "  With working kdump, that panic should enter the crash kernel and produce"
    log "  a vmcore according to the existing kdump configuration."
}

main "$@"
