#!/usr/bin/env bash
#
# ollama-healthcheck.sh - Ollama service and host security check.
#
#   1. Verify the Ollama service is running; restart it if not.
#   2. Verify the API is bound to loopback rather than 0.0.0.0.
#   3. Warn if the filesystem holding ~/.ollama/models is above 80% used.
#   4. Show the last 5 failed SSH login attempts.
#
# Exit codes:  0 = healthy   1 = warnings raised   2 = script/usage error
#
# Usage:
#   ./ollama-healthcheck.sh [-t PCT] [-p PORT] [-n COUNT] [-q] [-N] [-h]
#
#   -t PCT    disk usage percentage that triggers a warning (default 80)
#   -p PORT   Ollama port (default 11434)
#   -n COUNT  number of failed SSH attempts to show (default 5)
#   -q        quiet: only print warnings and the final verdict
#   -N        no-restart: report a stopped service but do not start it
#   -h        show this help

set -uo pipefail
# Deliberately not using `set -e`: a failing individual check should be
# reported and the remaining checks should still run.

# ------------------------------------------------------------------ config
THRESHOLD=80
PORT=11434
SSH_COUNT=5
QUIET=0
NO_RESTART=0
SERVICE_NAME="ollama"
MODELS_DIR="${OLLAMA_MODELS:-$HOME/.ollama/models}"

WARNINGS=()
warn() { WARNINGS+=("$1"); printf '%b  ! %s%b\n' "$C_YELLOW" "$1" "$C_RESET" >&2; }

# ------------------------------------------------------------------ colours
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    C_RESET=$(tput sgr0); C_BOLD=$(tput bold)
    C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2)
    C_YELLOW=$(tput setaf 3); C_CYAN=$(tput setaf 6)
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

say()  { [[ $QUIET -eq 1 ]] || printf '%s\n' "$*"; }
ok()   { [[ $QUIET -eq 1 ]] || printf '%b  + %s%b\n' "$C_GREEN" "$*" "$C_RESET"; }
info() { [[ $QUIET -eq 1 ]] || printf '    %s\n' "$*"; }
head_() {
    [[ $QUIET -eq 1 ]] && return 0
    printf '\n%b%s%b\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"
    printf '%s\n' "------------------------------------------------------------"
}

usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ------------------------------------------------------------------ args
while getopts ':t:p:n:qNh' opt; do
    case "$opt" in
        t) THRESHOLD=$OPTARG ;;
        p) PORT=$OPTARG ;;
        n) SSH_COUNT=$OPTARG ;;
        q) QUIET=1 ;;
        N) NO_RESTART=1 ;;
        h) usage 0 ;;
        :) printf 'Option -%s requires an argument.\n' "$OPTARG" >&2; usage 2 ;;
        \?) printf 'Unknown option: -%s\n' "$OPTARG" >&2; usage 2 ;;
    esac
done

[[ "$THRESHOLD" =~ ^[0-9]+$ && $THRESHOLD -ge 1 && $THRESHOLD -le 99 ]] || {
    printf 'Threshold must be an integer 1-99.\n' >&2; exit 2; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { printf 'Port must be numeric.\n' >&2; exit 2; }
[[ "$SSH_COUNT" =~ ^[0-9]+$ ]] || { printf 'Count must be numeric.\n' >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }

# systemd is not always present (containers, WSL, macOS).
HAS_SYSTEMD=0
if have systemctl && [[ -d /run/systemd/system ]]; then HAS_SYSTEMD=1; fi

# ------------------------------------------------------------------ header
say "============================================================"
say "  OLLAMA HEALTH CHECK"
say "============================================================"
say "  Host      : $(hostname)"
say "  User      : $(id -un)"
say "  Date      : $(date '+%Y-%m-%d %H:%M:%S %Z')"
say "  Models dir: $MODELS_DIR"

# ============================================================ 1. SERVICE
head_ "1. OLLAMA SERVICE"

service_is_up() {
    if [[ $HAS_SYSTEMD -eq 1 ]] && systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
        systemctl is-active --quiet "$SERVICE_NAME" && return 0
        return 1
    fi
    pgrep -x ollama >/dev/null 2>&1 && return 0
    return 1
}

# The process can be alive while the API is wedged, so probe the endpoint too.
api_responds() {
    if have curl; then
        curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/version" >/dev/null 2>&1
    elif have wget; then
        wget -q -T 5 -O /dev/null "http://127.0.0.1:${PORT}/api/version" 2>/dev/null
    else
        return 2   # cannot determine
    fi
}

RESTARTED=0
if service_is_up; then
    ok "Service is running."
else
    warn "Ollama is not running."
    if [[ $NO_RESTART -eq 1 ]]; then
        info "Restart suppressed (-N)."
    else
        info "Attempting restart..."
        if [[ $HAS_SYSTEMD -eq 1 ]] && systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
            SUDO=""
            [[ $EUID -ne 0 ]] && have sudo && SUDO="sudo -n"
            if $SUDO systemctl restart "$SERVICE_NAME" 2>/dev/null; then
                sleep 3
                if service_is_up; then ok "Restarted via systemd."; RESTARTED=1
                else warn "systemd restart issued but the service is still down."; fi
            else
                warn "Could not restart via systemd (needs root, or sudo requires a password)."
                info "Try: sudo systemctl restart $SERVICE_NAME"
            fi
        elif have ollama; then
            # No unit file: start a detached background server.
            nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
            sleep 3
            if service_is_up; then
                ok "Started 'ollama serve' in the background (log: /tmp/ollama-serve.log)."
                RESTARTED=1
            else
                warn "Failed to start ollama; see /tmp/ollama-serve.log"
            fi
        else
            warn "The 'ollama' binary is not on PATH - cannot start it."
        fi
    fi
fi

if service_is_up; then
    api_responds; rc=$?
    case $rc in
        0) ok "API responding on 127.0.0.1:${PORT}." ;;
        2) info "Neither curl nor wget available - API probe skipped." ;;
        *) warn "Process is running but the API on port ${PORT} is not responding." ;;
    esac
    if have ollama; then
        v=$(ollama --version 2>/dev/null | head -n1)
        [[ -n "$v" ]] && info "Version: $v"
    fi
fi

# ============================================================ 2. BIND ADDRESS
head_ "2. BIND ADDRESS"

# OLLAMA_HOST as configured for this shell is only advisory - what matters is
# what the running process actually listens on.
if [[ -n "${OLLAMA_HOST:-}" ]]; then
    info "OLLAMA_HOST in this shell: $OLLAMA_HOST"
fi
if [[ $HAS_SYSTEMD -eq 1 ]]; then
    unit_host=$(systemctl show "$SERVICE_NAME" -p Environment 2>/dev/null | tr ' ' '\n' | grep '^OLLAMA_HOST=' || true)
    [[ -n "$unit_host" ]] && info "Unit environment: ${unit_host#Environment=}"
fi

LISTEN_RAW=""
if have ss; then
    LISTEN_RAW=$(ss -H -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {print $4}')
    [[ -z "$LISTEN_RAW" ]] && LISTEN_RAW=$(ss -H -ltn 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {print $4}')
elif have netstat; then
    LISTEN_RAW=$(netstat -ltn 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {print $4}')
elif have lsof; then
    LISTEN_RAW=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}')
fi

if [[ -z "$LISTEN_RAW" ]]; then
    info "No listener found on port ${PORT} (service may be down, or ss/netstat/lsof unavailable)."
else
    INSECURE=0
    while IFS= read -r ep; do
        [[ -z "$ep" ]] && continue
        addr=${ep%:*}
        addr=${addr#[}; addr=${addr%]}
        case "$addr" in
            127.0.0.1|::1|localhost)
                ok "Bound to loopback ($ep) - not reachable from the network." ;;
            0.0.0.0|::|'*')
                INSECURE=1
                warn "Ollama is listening on ALL interfaces ($ep) - the API is exposed to the network."
                ;;
            *)
                INSECURE=1
                warn "Ollama is bound to a non-loopback address ($ep) - reachable from the network."
                ;;
        esac
    done <<< "$LISTEN_RAW"

    if [[ $INSECURE -eq 1 ]]; then
        info ""
        info "Ollama has no authentication. Anything that can reach this port can"
        info "run inference, pull models, and delete them. To bind to loopback:"
        info ""
        info "  sudo systemctl edit $SERVICE_NAME"
        info "  # add:"
        info "  [Service]"
        info "  Environment=\"OLLAMA_HOST=127.0.0.1:${PORT}\""
        info ""
        info "  sudo systemctl daemon-reload && sudo systemctl restart $SERVICE_NAME"
        info ""
        info "If remote access is intended, put it behind a reverse proxy with"
        info "authentication and restrict the port at the firewall."
    fi
fi

# ============================================================ 3. DISK USAGE
head_ "3. MODEL STORAGE"

if [[ ! -d "$MODELS_DIR" ]]; then
    info "Directory not found: $MODELS_DIR"
    info "(Normal if no models have been pulled yet.)"
else
    read -r fs size used avail pct mount < <(df -Pk "$MODELS_DIR" 2>/dev/null | awk 'NR==2 {print $1, $2, $3, $4, $5, $6}')
    pct_num=${pct%\%}

    human() { awk -v k="$1" 'BEGIN{ s="KMGTP"; i=1; while (k>=1024 && i<5){k/=1024;i++} printf "%.1f%s", k, substr(s,i,1) }'; }

    info "Filesystem : $fs  (mounted on $mount)"
    info "Capacity   : $(human "$size")  used $(human "$used")  free $(human "$avail")"
    info "Usage      : ${pct} (threshold ${THRESHOLD}%)"

    if have du; then
        model_size=$(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)
        [[ -n "$model_size" ]] && info "Models dir : $model_size"
    fi
    if have ollama && service_is_up; then
        count=$(ollama list 2>/dev/null | tail -n +2 | grep -c . || true)
        [[ -n "$count" ]] && info "Models     : $count installed"
    fi

    if [[ "$pct_num" =~ ^[0-9]+$ ]] && [[ $pct_num -gt $THRESHOLD ]]; then
        warn "Filesystem holding the models is ${pct} full (threshold ${THRESHOLD}%)."
        info "Reclaim space with: ollama list  then  ollama rm <model>"
    else
        ok "Disk usage within threshold (${pct} used)."
    fi
fi

# ============================================================ 4. SSH FAILURES
head_ "4. LAST $SSH_COUNT FAILED SSH LOGIN ATTEMPTS"

ssh_failures() {
    # journalctl first (systemd hosts), then distro log files, then lastb.
    if have journalctl; then
        out=$(journalctl -u ssh -u sshd --no-pager -n 2000 2>/dev/null \
              | grep -Ei 'failed password|invalid user|authentication failure' \
              | tail -n "$SSH_COUNT")
        [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    fi
    for f in /var/log/auth.log /var/log/secure; do
        if [[ -r "$f" ]]; then
            out=$(grep -Ei 'failed password|invalid user|authentication failure' "$f" 2>/dev/null \
                  | tail -n "$SSH_COUNT")
            [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
        fi
    done
    if have lastb; then
        out=$(lastb -n "$SSH_COUNT" 2>/dev/null | grep -v '^$' | grep -v '^btmp begins')
        [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    fi
    return 1
}

if FAILS=$(ssh_failures); then
    printf '%s\n' "$FAILS" | sed 's/^/    /'

    # Only meaningful when the source was a text log rather than lastb.
    ips=$(printf '%s\n' "$FAILS" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | uniq -c | sort -rn)
    if [[ -n "$ips" ]]; then
        info ""
        info "Source addresses in this sample:"
        printf '%s\n' "$ips" | sed 's/^/      /'
    fi
    warn "Failed SSH login attempts present in the logs - review the sources above."
else
    if [[ $EUID -ne 0 ]]; then
        info "No entries found. Auth logs usually require root - re-run with sudo to be certain."
    else
        ok "No failed SSH login attempts found."
    fi
fi

# ============================================================ SUMMARY
say ""
say "============================================================"
say "  SUMMARY"
say "============================================================"
[[ $RESTARTED -eq 1 ]] && say "  Ollama was restarted during this run."

if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    printf '%b  HEALTHY - no issues detected.%b\n' "$C_GREEN" "$C_RESET"
    say "============================================================"
    exit 0
else
    printf '%b  %d WARNING(S):%b\n' "$C_RED" "${#WARNINGS[@]}" "$C_RESET"
    i=1
    for w in "${WARNINGS[@]}"; do
        printf '    %d. %s\n' "$i" "$w"
        i=$((i + 1))
    done
    say "============================================================"
    exit 1
fi
