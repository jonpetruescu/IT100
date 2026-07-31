#!/usr/bin/env bash
#
# sysinfo.sh - System Information Summary.
#
#   1. Identity: hostname, IP addresses, OS version, kernel, uptime
#   2. Disk usage for every real filesystem, flagging anything above 80%
#   3. Memory and CPU model
#
# The report is written to ~/sysinfo_<date>.txt and echoed to the console.
#
# Exit codes:  0 = nothing flagged   1 = one or more filesystems over threshold
#              2 = usage error or the report could not be written
#
# Usage:
#   ./sysinfo.sh [-t PCT] [-o DIR] [-a] [-q] [-h]
#
#   -t PCT   disk usage percentage that triggers a flag (default 80)
#   -o DIR   output directory (default $HOME)
#   -a       include pseudo filesystems (tmpfs, overlay, squashfs) in the disk table
#   -q       quiet: write the report but print only the final verdict
#   -h       show this help

set -uo pipefail
# Not using `set -e`: an individual probe that fails should be reported inline
# and the remaining sections should still be collected.

# ------------------------------------------------------------------ defaults
THRESHOLD=80
OUTDIR="$HOME"
SHOW_ALL=0
QUIET=0

usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ':t:o:aqh' opt; do
    case "$opt" in
        t) THRESHOLD=$OPTARG ;;
        o) OUTDIR=$OPTARG ;;
        a) SHOW_ALL=1 ;;
        q) QUIET=1 ;;
        h) usage 0 ;;
        :)  printf 'Option -%s requires an argument.\n' "$OPTARG" >&2; usage 2 ;;
        \?) printf 'Unknown option: -%s\n' "$OPTARG" >&2; usage 2 ;;
    esac
done

[[ "$THRESHOLD" =~ ^[0-9]+$ && $THRESHOLD -ge 1 && $THRESHOLD -le 99 ]] || {
    printf 'Threshold must be an integer between 1 and 99.\n' >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }

REPORT=""
FLAGGED=()
add() { REPORT+="$*"$'\n'; }
rule() { add "------------------------------------------------------------------------"; }
section() { add ""; rule; add "$*"; rule; }

# First non-empty value wins; used to collapse the many ways to read one fact.
first_of() {
    local v
    for v in "$@"; do
        [[ -n "${v// /}" ]] && { printf '%s' "$v"; return 0; }
    done
    printf 'unavailable'
}

START=$(date '+%Y-%m-%d %H:%M:%S %Z')

# ============================================================ HEADER
add "========================================================================"
add "                       SYSTEM INFORMATION SUMMARY"
add "========================================================================"
add "Generated : $START"
add "Script    : $(basename "$0")  (run by $(id -un))"

# ============================================================ 1. IDENTITY
section "1. SYSTEM IDENTITY"

HOSTNAME_SHORT=$(first_of "$(hostname -s 2>/dev/null)" "$(hostname 2>/dev/null)" "${HOSTNAME:-}")
HOSTNAME_FQDN=$(first_of "$(hostname -f 2>/dev/null)" "$HOSTNAME_SHORT")

add "Hostname       : $HOSTNAME_SHORT"
[[ "$HOSTNAME_FQDN" != "$HOSTNAME_SHORT" ]] && add "FQDN           : $HOSTNAME_FQDN"

# Primary IP: the address the kernel would source-select for outbound traffic.
# `ip route get` only consults the routing table, so it needs no connectivity.
PRIMARY_IP=""
if have ip; then
    PRIMARY_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
[[ -z "$PRIMARY_IP" ]] && have hostname && PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
# No default route (containers, isolated netns): fall back to the first
# globally-scoped address on any interface.
if [[ -z "$PRIMARY_IP" ]] && have ip; then
    PRIMARY_IP=$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
fi
add "Primary IP     : $(first_of "$PRIMARY_IP")"

# All non-loopback addresses, per interface.
if have ip; then
    while read -r iface addr; do
        [[ -n "$iface" ]] && add "  interface    : ${iface} -> ${addr}"
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2, $4}')
elif have ifconfig; then
    ifconfig 2>/dev/null | awk '/inet /{print "  address      : "$2}' | while read -r l; do add "$l"; done
fi

# OS: /etc/os-release is the standard; lsb_release and uname cover the rest.
OS_NAME=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    OS_NAME=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-${NAME:-} ${VERSION:-}}")
fi
[[ -z "${OS_NAME// /}" ]] && have lsb_release && OS_NAME=$(lsb_release -ds 2>/dev/null | tr -d '"')
[[ -z "${OS_NAME// /}" && -r /etc/redhat-release ]] && OS_NAME=$(cat /etc/redhat-release)
[[ -z "${OS_NAME// /}" ]] && OS_NAME=$(uname -o 2>/dev/null)

add "OS             : $(first_of "$OS_NAME")"
add "Kernel         : $(uname -r 2>/dev/null) ($(uname -m 2>/dev/null))"

# Virtualisation is worth knowing before you trust any of the hardware figures.
if have systemd-detect-virt; then
    VIRT=$(systemd-detect-virt 2>/dev/null)
    [[ -n "$VIRT" && "$VIRT" != "none" ]] && add "Virtualisation : $VIRT"
fi

# Uptime: /proc/uptime is the reliable source; `uptime -p` is prettier but
# absent on some busybox builds.
if [[ -r /proc/uptime ]]; then
    UP_SECS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    add "Uptime         : $((UP_SECS/86400))d $((UP_SECS%86400/3600))h $((UP_SECS%3600/60))m"
    add "Booted         : $(date -d "@$(( $(date +%s) - UP_SECS ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || uptime -s 2>/dev/null)"
elif have uptime; then
    add "Uptime         : $(uptime -p 2>/dev/null || uptime)"
fi

if [[ -r /proc/loadavg ]]; then
    add "Load average   : $(awk '{print $1", "$2", "$3}' /proc/loadavg)  (over 1, 5, 15 min)"
fi

# ============================================================ 2. DISK
section "2. DISK USAGE  (threshold ${THRESHOLD}%)"

# -P forces POSIX single-line output so long device names don't wrap and
# break field positions. -T adds the filesystem type.
DF_RAW=$(df -PTh 2>/dev/null | tail -n +2)
if [[ $SHOW_ALL -eq 0 ]]; then
    DF_RAW=$(printf '%s\n' "$DF_RAW" | grep -vE '^(tmpfs|devtmpfs|squashfs|overlay|udev|none)[[:space:]]' \
             | grep -vE '[[:space:]](tmpfs|devtmpfs|squashfs|overlay|ramfs|efivarfs|autofs)[[:space:]]')
fi

if [[ -z "${DF_RAW// /}" ]]; then
    add "No filesystems reported (try -a to include pseudo filesystems)."
else
    printf -v hdr '%-24s %-8s %7s %7s %7s %6s  %-20s %s' \
        'FILESYSTEM' 'TYPE' 'SIZE' 'USED' 'AVAIL' 'USE%' 'MOUNTED ON' 'STATUS'
    add "$hdr"
    add "$(printf '%.0s-' {1..104})"

    # Bind mounts and snap loopbacks report the same device many times over.
    # Collapse them to one row per device+mount-source so the table and the
    # flagged count reflect real volumes rather than mount points.
    declare -A SEEN_DEV=()

    while read -r fs type size used avail pct mount; do
        [[ -z "$fs" ]] && continue

        dev_key="${fs}|${size}|${used}"
        if [[ -n "${SEEN_DEV[$dev_key]:-}" ]]; then
            SEEN_DEV[$dev_key]="${SEEN_DEV[$dev_key]}, $mount"
            continue
        fi
        SEEN_DEV[$dev_key]="$mount"

        num=${pct%\%}
        status="ok"
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num > THRESHOLD )); then
            status="*** OVER THRESHOLD ***"
            FLAGGED+=("$mount ($pct used, $avail free, $fs)")
        fi
        add "$(printf '%-24s %-8s %7s %7s %7s %6s  %-20s %s' \
            "${fs:0:24}" "${type:0:8}" "$size" "$used" "$avail" "$pct" "${mount:0:20}" "$status")"
    done <<< "$DF_RAW"

    # Report any device that surfaced at more than one mount point.
    extra=""
    for k in "${!SEEN_DEV[@]}"; do
        if [[ "${SEEN_DEV[$k]}" == *", "* ]]; then
            extra+="  ${k%%|*} -> ${SEEN_DEV[$k]}"$'\n'
        fi
    done
    if [[ -n "$extra" ]]; then
        add ""
        add "Devices mounted at multiple paths (counted once above):"
        add "${extra%$'\n'}"
    fi

    # Inode exhaustion produces "no space left on device" on a disk that looks
    # half empty, so it is worth surfacing alongside block usage.
    INODE_HIGH=$(df -PTi 2>/dev/null | tail -n +2 \
        | grep -vE '^(tmpfs|devtmpfs|squashfs|overlay|udev|none)[[:space:]]' \
        | awk -v t="$THRESHOLD" '{ p=$6; gsub("%","",p); if (p ~ /^[0-9]+$/ && p+0 > t) print "  " $7 " -> " $6 " of inodes used" }')
    if [[ -n "$INODE_HIGH" ]]; then
        add ""
        add "Inode usage above threshold:"
        add "$INODE_HIGH"
        while read -r l; do [[ -n "$l" ]] && FLAGGED+=("inodes:${l#  }"); done <<< "$INODE_HIGH"
    fi
fi

# ============================================================ 3. MEMORY + CPU
section "3. MEMORY"

if [[ -r /proc/meminfo ]]; then
    # MemAvailable is the figure that matters - MemFree excludes reclaimable
    # cache and understates what applications can actually get.
    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    mem_free=$(awk '/^MemFree:/{print $2}' /proc/meminfo)
    swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
    [[ -z "$mem_avail" ]] && mem_avail=$mem_free

    gib() { awk -v k="$1" 'BEGIN{ printf "%.1f GiB", k/1048576 }'; }
    pctof() { awk -v a="$1" -v b="$2" 'BEGIN{ if(b>0) printf "%.1f", (a/b)*100; else print "0" }'; }

    add "Total          : $(gib "$mem_total")"
    add "Available      : $(gib "$mem_avail")  ($(pctof "$mem_avail" "$mem_total")%)"
    add "Used           : $(gib $((mem_total - mem_avail)))  ($(pctof $((mem_total - mem_avail)) "$mem_total")%)"
    if [[ "${swap_total:-0}" -gt 0 ]]; then
        add "Swap           : $(gib $((swap_total - swap_free))) used of $(gib "$swap_total")"
    else
        add "Swap           : none configured"
    fi
elif have free; then
    while read -r l; do add "$l"; done < <(free -h)
else
    add "Memory information unavailable."
fi

section "4. CPU"

# x86 exposes "model name" in /proc/cpuinfo. ARM does not - neither does
# lscpu on Apple-silicon VMs, which report only "Vendor ID" and "Model: 0".
# Walk the sources until something useful appears, then fall back to
# vendor + architecture rather than printing "unavailable".
CPU_MODEL=""
if [[ -r /proc/cpuinfo ]]; then
    CPU_MODEL=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)
    [[ -z "$CPU_MODEL" ]] && CPU_MODEL=$(awk -F': ' '/^Hardware|^Processor/{print $2; exit}' /proc/cpuinfo)
fi
if [[ -z "$CPU_MODEL" ]] && have lscpu; then
    CPU_MODEL=$(lscpu 2>/dev/null | awk -F': +' '/^Model name/{print $2; exit}')
    if [[ -z "$CPU_MODEL" || "$CPU_MODEL" == "-" ]]; then
        vendor=$(lscpu 2>/dev/null | awk -F': +' '/^Vendor ID/{print $2; exit}')
        arch=$(uname -m 2>/dev/null)
        [[ -n "$vendor" ]] && CPU_MODEL="$vendor $arch"
        # CPU implementer/part identify ARM cores when nothing else does.
        if [[ -r /proc/cpuinfo ]]; then
            part=$(awk -F': ' '/^CPU part/{print $2; exit}' /proc/cpuinfo)
            [[ -n "$part" ]] && CPU_MODEL="${CPU_MODEL:-$arch} (CPU part $part)"
        fi
    fi
fi
CPU_MODEL=$(printf '%s' "$CPU_MODEL" | sed 's/  */ /g; s/^ *//; s/ *$//')

CPU_COUNT=$(first_of "$(nproc 2>/dev/null)" "$(grep -c ^processor /proc/cpuinfo 2>/dev/null)")

add "Model          : $(first_of "$CPU_MODEL")"
add "Logical cores  : $CPU_COUNT"

if have lscpu; then
    while IFS= read -r line; do add "$line"; done < <(
        # Skip fields lscpu reports as "-" or "0" on virtualised hardware.
        lscpu 2>/dev/null | awk -F': +' '
            $2 == "-" || $2 == "0" || $2 == "" {next}
            /^Architecture/       {printf "Architecture   : %s\n", $2}
            /^Socket\(s\)/        {printf "Sockets        : %s\n", $2}
            /^Core\(s\) per socket/{printf "Cores/socket   : %s\n", $2}
            /^Thread\(s\) per core/{printf "Threads/core   : %s\n", $2}
            /^CPU max MHz/        {printf "Max clock      : %.0f MHz\n", $2}
        ')
fi

if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    [[ "$t" =~ ^[0-9]+$ ]] && add "Temperature    : $((t/1000))C"
fi

# ============================================================ SUMMARY
add ""
add "========================================================================"
add "SUMMARY"
add "========================================================================"
if [[ ${#FLAGGED[@]} -eq 0 ]]; then
    add "OK - no filesystem above ${THRESHOLD}%."
else
    add "${#FLAGGED[@]} filesystem(s) above ${THRESHOLD}%:"
    i=1
    for f in "${FLAGGED[@]}"; do add "  $i. $f"; i=$((i+1)); done
fi
add "========================================================================"

# ============================================================ WRITE
if ! mkdir -p "$OUTDIR" 2>/dev/null; then
    printf 'Cannot create output directory: %s\n' "$OUTDIR" >&2; exit 2
fi
OUTFILE="$OUTDIR/sysinfo_$(hostname -s 2>/dev/null || echo host)_$(date '+%Y-%m-%d_%H%M%S').txt"

if ! printf '%s' "$REPORT" > "$OUTFILE" 2>/dev/null; then
    printf 'Could not write report to: %s\n' "$OUTFILE" >&2; exit 2
fi

if [[ $QUIET -eq 0 ]]; then
    printf '%s' "$REPORT"
    printf '\nReport saved to: %s\n' "$OUTFILE"
else
    printf '%s\n' "$OUTFILE"
fi

exit $(( ${#FLAGGED[@]} > 0 ? 1 : 0 ))
