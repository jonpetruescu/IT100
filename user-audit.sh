#!/usr/bin/env bash
#
# user-audit.sh - Local user account audit.
#
#   1. List every account with a real login shell (excluding nologin/false)
#   2. Identify which of those have sudo rights, and how they got them
#   3. Flag any account with UID 0 other than root
#
# Additional findings reported alongside the above, because they are the
# things a UID-0 check is usually a proxy for:
#   - accounts with an empty password field (login with no credential)
#   - passwordless sudo (NOPASSWD) grants
#   - unlocked accounts that have never set a password
#
# Exit codes:  0 = nothing flagged   1 = findings present   2 = usage error
#
# Usage:
#   ./user-audit.sh [-o FILE] [-s] [-q] [-h]
#
#   -o FILE  also write the report to FILE (CSV if the name ends in .csv)
#   -s       system accounts too (default: only UID >= 1000, plus root)
#   -q       quiet: print only the summary
#   -h       show this help
#
# Run as root for complete results: /etc/shadow and sudoers are not
# world-readable, so an unprivileged run cannot see password state or
# per-user sudoers entries.

set -uo pipefail

OUTFILE=""
SHOW_SYSTEM=0
QUIET=0
UID_MIN=1000

usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ':o:sqh' opt; do
    case "$opt" in
        o) OUTFILE=$OPTARG ;;
        s) SHOW_SYSTEM=1 ;;
        q) QUIET=1 ;;
        h) usage 0 ;;
        :)  printf 'Option -%s requires an argument.\n' "$OPTARG" >&2; usage 2 ;;
        \?) printf 'Unknown option: -%s\n' "$OPTARG" >&2; usage 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }
IS_ROOT=0; [[ $EUID -eq 0 ]] && IS_ROOT=1

if [[ -t 1 ]] && have tput && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    R=$(tput sgr0); B=$(tput bold); RED=$(tput setaf 1); GRN=$(tput setaf 2); YEL=$(tput setaf 3)
else
    R=""; B=""; RED=""; GRN=""; YEL=""
fi

OUT=""
FINDINGS=()
say()  { OUT+="$*"$'\n'; [[ $QUIET -eq 1 ]] || printf '%s\n' "$*"; }
rule() { say "------------------------------------------------------------------------"; }
flag() { FINDINGS+=("$1"); }

# ============================================================ collect sudoers
# Group-based grants first. Group names differ by distro: sudo on Debian,
# wheel on RHEL/Arch, admin on older Ubuntu.
declare -A SUDO_VIA=()          # user -> how they got sudo
declare -A NOPASSWD_USERS=()

add_sudo() {
    local u="$1" how="$2"
    if [[ -n "${SUDO_VIA[$u]:-}" ]]; then
        [[ "${SUDO_VIA[$u]}" == *"$how"* ]] || SUDO_VIA[$u]="${SUDO_VIA[$u]}, $how"
    else
        SUDO_VIA[$u]="$how"
    fi
}

for g in sudo wheel admin sudoers; do
    line=$(getent group "$g" 2>/dev/null) || continue
    [[ -z "$line" ]] && continue
    gid=$(printf '%s' "$line" | cut -d: -f3)
    members=$(printf '%s' "$line" | cut -d: -f4)

    IFS=',' read -ra arr <<< "$members"
    for m in "${arr[@]}"; do
        [[ -n "$m" ]] && add_sudo "$m" "group:$g"
    done

    # Users whose *primary* GID is the sudo group do not appear in the
    # group's member list, so they must be picked up separately.
    while IFS=: read -r pu _ puid pgid _; do
        [[ "$pgid" == "$gid" ]] && add_sudo "$pu" "group:$g(primary)"
    done < <(getent passwd 2>/dev/null)
done

# Direct sudoers entries. Readable only as root; note the gap otherwise.
SUDOERS_READABLE=0
parse_sudoers_file() {
    local f="$1"
    [[ -r "$f" ]] || return 1
    SUDOERS_READABLE=1
    # Strip comments, keep lines granting rights to a plain username.
    while IFS= read -r l; do
        l="${l%%#*}"
        [[ -z "${l// /}" ]] && continue
        [[ "$l" =~ ^[[:space:]]*(Defaults|User_Alias|Runas_Alias|Host_Alias|Cmnd_Alias) ]] && continue
        if [[ "$l" =~ ^[[:space:]]*%([A-Za-z0-9_.-]+)[[:space:]]+.*= ]]; then
            grp="${BASH_REMATCH[1]}"
            gl=$(getent group "$grp" 2>/dev/null | cut -d: -f4)
            IFS=',' read -ra ga <<< "${gl:-}"
            for m in "${ga[@]}"; do
                [[ -n "$m" ]] && add_sudo "$m" "sudoers:%$grp"
                [[ -n "$m" && "$l" == *NOPASSWD* ]] && NOPASSWD_USERS[$m]=1
            done
        elif [[ "$l" =~ ^[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]+.*= ]]; then
            u="${BASH_REMATCH[1]}"
            [[ "$u" == "root" ]] && continue
            add_sudo "$u" "sudoers:$(basename "$f")"
            [[ "$l" == *NOPASSWD* ]] && NOPASSWD_USERS[$u]=1
        fi
    done < "$f"
    return 0
}

parse_sudoers_file /etc/sudoers
if [[ -d /etc/sudoers.d ]]; then
    for f in /etc/sudoers.d/*; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == *~ || "$(basename "$f")" == *.bak ]] && continue
        parse_sudoers_file "$f"
    done
fi

# ============================================================ header
say "========================================================================"
say "                        LOCAL USER AUDIT"
say "========================================================================"
say "Host      : $(hostname 2>/dev/null)"
say "Date      : $(date '+%Y-%m-%d %H:%M:%S %Z')"
say "Run as    : $(id -un) $([[ $IS_ROOT -eq 1 ]] && echo '(root - full visibility)' || echo '(unprivileged - see notes)')"
say "Scope     : $([[ $SHOW_SYSTEM -eq 1 ]] && echo 'all accounts' || echo "UID >= $UID_MIN, plus root")"

# ============================================================ 1. LOGIN SHELLS
say ""
rule
say "1. ACCOUNTS WITH A LOGIN SHELL"
rule

# An account is "able to log in" if its shell is not one of the deliberate
# no-login shells. /sbin/nologin and /bin/false are the usual pair; sync,
# shutdown and halt are legacy special-purpose shells.
is_login_shell() {
    case "$1" in
        */nologin|*/false|/bin/sync|/sbin/shutdown|/sbin/halt|"") return 1 ;;
        *) return 0 ;;
    esac
}

printf -v HDR '%-18s %6s %6s %-24s %-10s %s' 'USER' 'UID' 'GID' 'SHELL' 'PASSWORD' 'SUDO'
say "$HDR"
say "$(printf '%.0s-' {1..96})"

ROWS=""
LOGIN_COUNT=0
declare -a UID0_OTHER=()

while IFS=: read -r user _ uid gid gecos home shell; do
    [[ -z "$user" ]] && continue

    # UID 0 duplicates are checked across ALL accounts regardless of scope -
    # a hidden root-equivalent will not have a UID above 1000.
    if [[ "$uid" == "0" && "$user" != "root" ]]; then
        UID0_OTHER+=("$user")
    fi

    if [[ $SHOW_SYSTEM -eq 0 ]]; then
        # UID 0 accounts are never filtered out by scope. A rogue root-equivalent
        # sits below UID_MIN and would otherwise be hidden from this table -
        # which is precisely the row an auditor needs to see.
        [[ "$uid" -lt "$UID_MIN" && "$user" != "root" && "$uid" != "0" ]] && continue
        [[ "$uid" -eq 65534 ]] && continue     # nobody
    fi

    is_login_shell "$shell" || continue
    LOGIN_COUNT=$((LOGIN_COUNT + 1))

    # Password state. Field 2 of /etc/shadow: "!"/"*" prefix = locked,
    # empty = NO PASSWORD REQUIRED, anything else = a hash is set.
    pwstate="unknown"
    if [[ $IS_ROOT -eq 1 && -r /etc/shadow ]]; then
        hash=$(awk -F: -v u="$user" '$1==u{print $2}' /etc/shadow)
        case "$hash" in
            "")        pwstate="EMPTY"; flag "$user has an EMPTY password - login with no credential" ;;
            '!'*|'*'*) pwstate="locked" ;;
            *)         pwstate="set" ;;
        esac
    elif have passwd; then
        st=$(passwd -S "$user" 2>/dev/null | awk '{print $2}')
        case "$st" in
            P)  pwstate="set" ;;
            L)  pwstate="locked" ;;
            NP) pwstate="EMPTY"; flag "$user has an EMPTY password - login with no credential" ;;
            *)  pwstate="unknown" ;;
        esac
    fi

    sudo_note="${SUDO_VIA[$user]:-no}"
    [[ -n "${NOPASSWD_USERS[$user]:-}" ]] && sudo_note="$sudo_note [NOPASSWD]"
    [[ "$user" == "root" ]] && sudo_note="n/a (is root)"
    [[ "$uid" == "0" && "$user" != "root" ]] && sudo_note="*** UID 0 - ROOT EQUIVALENT ***"

    say "$(printf '%-18s %6s %6s %-24s %-10s %s' \
        "${user:0:18}" "$uid" "$gid" "${shell:0:24}" "$pwstate" "$sudo_note")"

    # The sudo_via field legitimately contains commas ("group:sudo, sudoers:%sudo"),
    # so every field is quoted and embedded quotes are doubled, per RFC 4180.
    csv_q() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }
    ROWS+="$(csv_q "$user"),$(csv_q "$uid"),$(csv_q "$gid"),$(csv_q "$shell"),$(csv_q "$pwstate"),$(csv_q "${SUDO_VIA[$user]:-none}"),$(csv_q "${NOPASSWD_USERS[$user]:+yes}")"$'\n'
done < <(getent passwd 2>/dev/null)

if [[ $LOGIN_COUNT -eq 0 ]]; then
    say "(none)"
fi
say ""
say "$LOGIN_COUNT account(s) with a login shell."
[[ $SHOW_SYSTEM -eq 0 ]] && say "System accounts hidden - re-run with -s to include them."

# ============================================================ 2. SUDO
say ""
rule
say "2. SUDO RIGHTS"
rule

if [[ ${#SUDO_VIA[@]} -eq 0 ]]; then
    say "No accounts found with sudo rights."
else
    printf -v SHDR '%-18s %-40s %s' 'USER' 'GRANTED VIA' 'NOPASSWD'
    say "$SHDR"
    say "$(printf '%.0s-' {1..76})"
    for u in $(printf '%s\n' "${!SUDO_VIA[@]}" | sort); do
        np="no"
        if [[ -n "${NOPASSWD_USERS[$u]:-}" ]]; then
            np="YES"
            flag "$u has passwordless sudo (NOPASSWD)"
        fi
        # A sudo grant pointing at an account that no longer exists is a
        # stale rule, and will silently apply if the name is ever recreated.
        if ! getent passwd "$u" >/dev/null 2>&1; then
            say "$(printf '%-18s %-40s %s' "$u" "${SUDO_VIA[$u]}" "$np  <- NO SUCH USER")"
            flag "sudo grant for '$u', which is not an existing account (stale rule)"
        else
            say "$(printf '%-18s %-40s %s' "${u:0:18}" "${SUDO_VIA[$u]:0:40}" "$np")"
        fi
    done
fi

if [[ $SUDOERS_READABLE -eq 0 ]]; then
    say ""
    say "NOTE: /etc/sudoers is not readable by this user, so only group-based"
    say "      grants were detected. Re-run as root for per-user sudoers rules."
fi

# ============================================================ 3. UID 0
say ""
rule
say "3. UID 0 ACCOUNTS"
rule

if [[ ${#UID0_OTHER[@]} -eq 0 ]]; then
    say "OK - root is the only account with UID 0."
else
    for u in "${UID0_OTHER[@]}"; do
        shell=$(getent passwd "$u" | cut -d: -f7)
        home=$(getent passwd "$u" | cut -d: -f6)
        say "*** $u has UID 0 - full root privileges ***"
        say "      shell: $shell"
        say "      home : $home"
        flag "$u has UID 0 (root-equivalent) - investigate immediately"
    done
    say ""
    say "A second UID 0 account is root by another name. Unless this was a"
    say "deliberate, documented change, treat it as a compromise indicator:"
    say "check its shell, home directory, authorized_keys, and creation time."
fi

# ============================================================ SUMMARY
say ""
say "========================================================================"
say "SUMMARY"
say "========================================================================"
say "Login-capable accounts : $LOGIN_COUNT"
say "Accounts with sudo     : ${#SUDO_VIA[@]}"
say "UID 0 besides root     : ${#UID0_OTHER[@]}"
say ""

if [[ ${#FINDINGS[@]} -eq 0 ]]; then
    say "RESULT: no findings."
    VERDICT_COLOUR=$GRN
else
    say "RESULT: ${#FINDINGS[@]} finding(s)"
    i=1
    for f in "${FINDINGS[@]}"; do say "  $i. $f"; i=$((i+1)); done
    VERDICT_COLOUR=$RED
fi

if [[ $IS_ROOT -eq 0 ]]; then
    say ""
    say "NOTE: run as root for password state and full sudoers visibility."
fi
say "========================================================================"

if [[ $QUIET -eq 1 ]]; then
    if [[ ${#FINDINGS[@]} -eq 0 ]]; then
        printf '%bOK%b - %d login accounts, %d with sudo, no findings.\n' "$GRN" "$R" "$LOGIN_COUNT" "${#SUDO_VIA[@]}"
    else
        printf '%b%d FINDING(S)%b - %d login accounts, %d with sudo.\n' \
            "$RED$B" "${#FINDINGS[@]}" "$R" "$LOGIN_COUNT" "${#SUDO_VIA[@]}"
        for f in "${FINDINGS[@]}"; do printf '  - %s\n' "$f"; done
    fi
fi

# ============================================================ output file
if [[ -n "$OUTFILE" ]]; then
    if [[ "$OUTFILE" == *.csv ]]; then
        { printf 'user,uid,gid,shell,password_state,sudo_via,nopasswd\n'; printf '%s' "$ROWS"; } > "$OUTFILE" 2>/dev/null \
            && [[ $QUIET -eq 0 ]] && printf '\nCSV written to: %s\n' "$OUTFILE"
    else
        printf '%s' "$OUT" > "$OUTFILE" 2>/dev/null \
            && [[ $QUIET -eq 0 ]] && printf '\nReport written to: %s\n' "$OUTFILE"
    fi
    [[ -f "$OUTFILE" ]] || printf 'Warning: could not write %s\n' "$OUTFILE" >&2
fi

exit $(( ${#FINDINGS[@]} > 0 ? 1 : 0 ))
