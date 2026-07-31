#!/usr/bin/env bash
#
# ollama-monitor.sh - Script B. SVUSD Ollama governance monitor.
#
# Extends the basic health check with the two controls the district's AI
# governance policy actually depends on:
#
#   * UNAUTHORIZED MODEL DETECTION - every installed model is compared against
#     an approved list. Anything not on the list is reported as a policy
#     violation, because an un-vetted model on a district server is an
#     un-vetted model handling district prompts.
#
#   * NETWORK EXPOSURE ALERT - if the API is bound to 0.0.0.0 (or any
#     non-loopback address) the script raises a CRITICAL alert. Ollama has no
#     authentication of any kind, so a non-loopback bind puts an open
#     inference endpoint on the school network.
#
# Also checked: service state, API reachability, model disk usage, and journal
# errors in the last hour.
#
# Exit codes (Nagios convention, for monitoring integration):
#   0 = HEALTHY   1 = WARNING   2 = CRITICAL   3 = UNKNOWN / usage error
#
# Usage:
#   ./ollama-monitor.sh [-a FILE] [-p PORT] [-t PCT] [-H HOURS]
#                       [-o FILE] [-m EMAIL] [-q] [-h]
#
#   -a FILE   approved model list (default /etc/svusd/approved-models.txt)
#   -p PORT   Ollama port (default 11434)
#   -t PCT    model disk threshold (default 80)
#   -H HOURS  journal lookback in hours (default 1)
#   -o FILE   write the report to FILE
#   -m EMAIL  mail the report to EMAIL when the result is not HEALTHY
#   -q        quiet: print only the verdict
#   -h        show this help
#
# Approved list format: one model per line, '#' starts a comment.
# A bare name ("llama3.1") matches any tag of that model. A name with a tag
# ("llama3.1:8b") matches only that exact tag.
#
#   Author : Jon Petruescu
#   Course : IT100, Summer 2027

set -uo pipefail

APPROVED_FILE="/etc/svusd/approved-models.txt"
PORT=11434
THRESHOLD=80
JOURNAL_HOURS=1
OUTFILE=""
MAILTO=""
QUIET=0
SERVICE="ollama"
MODELS_DIR="${OLLAMA_MODELS:-/var/lib/ollama/models}"

usage() { sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ':a:p:t:H:o:m:qh' opt; do
    case "$opt" in
        a) APPROVED_FILE=$OPTARG ;;
        p) PORT=$OPTARG ;;
        t) THRESHOLD=$OPTARG ;;
        H) JOURNAL_HOURS=$OPTARG ;;
        o) OUTFILE=$OPTARG ;;
        m) MAILTO=$OPTARG ;;
        q) QUIET=1 ;;
        h) usage 0 ;;
        :)  printf 'Option -%s requires an argument.\n' "$OPTARG" >&2; usage 3 ;;
        \?) printf 'Unknown option: -%s\n' "$OPTARG" >&2; usage 3 ;;
    esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] || { printf 'Port must be numeric.\n' >&2; exit 3; }
[[ "$THRESHOLD" =~ ^[0-9]+$ && $THRESHOLD -ge 1 && $THRESHOLD -le 99 ]] || {
    printf 'Threshold must be 1-99.\n' >&2; exit 3; }
[[ "$JOURNAL_HOURS" =~ ^[0-9]+$ ]] || { printf 'Hours must be numeric.\n' >&2; exit 3; }

have() { command -v "$1" >/dev/null 2>&1; }

if [[ -t 1 ]] && have tput && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    R=$(tput sgr0); B=$(tput bold)
    RED=$(tput setaf 1); GRN=$(tput setaf 2); YEL=$(tput setaf 3); CYN=$(tput setaf 6)
else
    R=""; B=""; RED=""; GRN=""; YEL=""; CYN=""
fi

N_PASS=0; N_WARN=0; N_FAIL=0; N_SKIP=0
LOG=""
ALERTS=()

record() {
    local status="$1" label="$2" detail="${3:-}" colour tag
    case "$status" in
        PASS) colour=$GRN; N_PASS=$((N_PASS+1)) ;;
        WARN) colour=$YEL; N_WARN=$((N_WARN+1)) ;;
        FAIL) colour=$RED; N_FAIL=$((N_FAIL+1)) ;;
        SKIP) colour=$CYN; N_SKIP=$((N_SKIP+1)) ;;
    esac
    tag=$(printf '[ %-4s ]' "$status")
    LOG+=$(printf '%s %-36s %s' "$tag" "$label" "$detail")$'\n'
    [[ $QUIET -eq 1 ]] || printf '%b%s%b %-36s %s\n' "$colour" "$tag" "$R" "$label" "$detail"
}

note() {
    LOG+="           $*"$'\n'
    [[ $QUIET -eq 1 ]] || printf '           %s\n' "$*"
}

alert() { ALERTS+=("$1"); }

HDR="SVUSD OLLAMA GOVERNANCE MONITOR - $(hostname 2>/dev/null) - $(date '+%Y-%m-%d %H:%M:%S %Z')"
LOG+="$HDR"$'\n'
LOG+="========================================================================"$'\n'
if [[ $QUIET -eq 0 ]]; then
    printf '%b========================================================================%b\n' "$B" "$R"
    printf '%b  %s%b\n' "$B" "$HDR" "$R"
    printf '%b========================================================================%b\n' "$B" "$R"
fi

HAS_SYSTEMD=0
if have systemctl && [[ -d /run/systemd/system ]]; then HAS_SYSTEMD=1; fi

# ============================================================ 1. SERVICE
SERVICE_UP=0
if [[ $HAS_SYSTEMD -eq 1 ]] && systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE}\.service"; then
    state=$(systemctl is-active "$SERVICE" 2>/dev/null)
    if [[ "$state" == "active" ]]; then
        SERVICE_UP=1
        record PASS "Ollama service running" "active"
    else
        record FAIL "Ollama service running" "systemctl reports: ${state:-unknown}"
        alert "Ollama service is not running (state: ${state:-unknown})"
    fi
elif pgrep -x ollama >/dev/null 2>&1; then
    SERVICE_UP=1
    record PASS "Ollama service running" "process up (pid $(pgrep -x ollama | head -1)), no systemd unit"
else
    record FAIL "Ollama service running" "no ollama.service unit and no ollama process"
    alert "Ollama is not running on $(hostname)"
fi

# ============================================================ 2. NETWORK EXPOSURE
# The headline control. Ollama ships with no authentication, so the bind
# address is the entire access control model.
LISTEN=""
if have ss; then
    LISTEN=$(ss -tuln 2>/dev/null | awk -v p=":$PORT" '$5 ~ p"$" {print $5}')
elif have netstat; then
    LISTEN=$(netstat -tuln 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {print $4}')
elif have lsof; then
    LISTEN=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}')
fi

EXPOSED=0
if [[ -z "$LISTEN" ]]; then
    if [[ $SERVICE_UP -eq 1 ]]; then
        record FAIL "API bound to loopback only" "service up but nothing listening on :$PORT"
    else
        record SKIP "API bound to loopback only" "no listener on :$PORT (service is down)"
    fi
else
    LOOPBACK=0
    while IFS= read -r ep; do
        [[ -z "$ep" ]] && continue
        a=${ep%:*}; a=${a#[}; a=${a%]}
        case "$a" in
            127.0.0.1|::1|localhost) LOOPBACK=1 ;;
            0.0.0.0|::|'*')          EXPOSED=1; EXPOSED_EP="$ep" ;;
            *)                       EXPOSED=1; EXPOSED_EP="$ep" ;;
        esac
    done <<< "$LISTEN"

    if [[ $EXPOSED -eq 1 ]]; then
        record FAIL "API bound to loopback only" "EXPOSED on ${EXPOSED_EP}"
        note "*** The inference API is reachable from the network. ***"
        note "Ollama performs no authentication. Any device that can route to"
        note "this host can run inference, pull models, and delete them."
        note "Remediate now:"
        note "  sudo systemctl edit ollama"
        note "    [Service]"
        note "    Environment=\"OLLAMA_HOST=127.0.0.1:$PORT\""
        note "  sudo systemctl daemon-reload && sudo systemctl restart ollama"
        note "  sudo ufw deny $PORT/tcp"
        alert "CRITICAL: Ollama API exposed on ${EXPOSED_EP} - unauthenticated inference endpoint reachable from the network"
    elif [[ $LOOPBACK -eq 1 ]]; then
        record PASS "API bound to loopback only" "$(printf '%s' "$LISTEN" | tr '\n' ' ')"
    else
        record WARN "API bound to loopback only" "unrecognised bind address: $LISTEN"
    fi
fi

# ============================================================ 2b. FIREWALL
# Defence in depth: even bound to loopback, the port should be denied at the
# host firewall so a misconfiguration does not immediately become exposure.
if have ufw; then
    ufw_state=$(ufw status 2>/dev/null | head -1)
    if [[ "$ufw_state" == *inactive* ]]; then
        record WARN "UFW active" "firewall is inactive"
        note "Enable with: sudo ufw enable"
    elif [[ -z "$ufw_state" ]]; then
        record SKIP "UFW active" "ufw status unreadable (needs root)"
    else
        if ufw status 2>/dev/null | grep -qE "^${PORT}(/tcp)?[[:space:]]+(DENY|REJECT)"; then
            record PASS "UFW active" "active, port $PORT explicitly denied"
        else
            record PASS "UFW active" "active (no explicit rule for $PORT)"
        fi
    fi
else
    record SKIP "UFW active" "ufw not installed"
fi

# ============================================================ 3. API
MODEL_JSON=""
if have curl; then
    MODEL_JSON=$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/tags" 2>/dev/null)
    rc=$?
    if [[ $rc -eq 0 && -n "$MODEL_JSON" ]]; then
        ver=$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/version" 2>/dev/null \
              | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/')
        record PASS "API responding" "/api/tags OK${ver:+, version $ver}"
    else
        record FAIL "API responding" "no valid response from 127.0.0.1:${PORT} (curl rc=$rc)"
        alert "Ollama API not responding on $(hostname)"
    fi
else
    record SKIP "API responding" "curl not installed"
fi

# ============================================================ 4. MODEL INVENTORY
# Prefer the API: it is authoritative and needs no CLI on the box.
INSTALLED=""
if [[ -n "$MODEL_JSON" ]]; then
    if have python3; then
        INSTALLED=$(printf '%s' "$MODEL_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    for m in d.get("models", []):
        n = m.get("name") or m.get("model") or ""
        if n: print(n)
except Exception:
    pass' 2>/dev/null)
    fi
    # No python3: fall back to extracting the name fields with grep.
    if [[ -z "$INSTALLED" ]]; then
        INSTALLED=$(printf '%s' "$MODEL_JSON" \
            | grep -oE '"(name|model)"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | sed 's/.*"\([^"]*\)"$/\1/' | sort -u)
    fi
fi
if [[ -z "$INSTALLED" ]] && have ollama; then
    INSTALLED=$(ollama list 2>/dev/null | tail -n +2 | awk 'NF{print $1}')
fi

MODEL_COUNT=0
[[ -n "$INSTALLED" ]] && MODEL_COUNT=$(printf '%s\n' "$INSTALLED" | grep -c '[^[:space:]]')

# ============================================================ 5. APPROVED LIST
if [[ ! -r "$APPROVED_FILE" ]]; then
    record SKIP "All models on approved list" "approved list not readable: $APPROVED_FILE"
    note "Create it with one model per line. Bare name matches any tag."
elif [[ -z "$INSTALLED" ]]; then
    record SKIP "All models on approved list" "could not enumerate installed models"
else
    # Build the approved set, stripping comments and blank lines.
    APPROVED=$(grep -vE '^[[:space:]]*(#|$)' "$APPROVED_FILE" | sed 's/[[:space:]]*#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep .)

    UNAUTHORIZED=""
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        base="${m%%:*}"
        ok=0
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            if [[ "$a" == *:* ]]; then
                # Tagged entry: exact match only.
                [[ "$m" == "$a" ]] && { ok=1; break; }
            else
                # Bare entry: any tag of that model is approved.
                [[ "$base" == "$a" ]] && { ok=1; break; }
            fi
        done <<< "$APPROVED"
        [[ $ok -eq 0 ]] && UNAUTHORIZED+="$m"$'\n'
    done <<< "$INSTALLED"

    UNAUTH_COUNT=$(printf '%s' "$UNAUTHORIZED" | grep -c '[^[:space:]]' || true)

    if [[ "${UNAUTH_COUNT:-0}" -eq 0 ]]; then
        record PASS "All models on approved list" "$MODEL_COUNT model(s), all approved"
    else
        record FAIL "All models on approved list" "$UNAUTH_COUNT of $MODEL_COUNT model(s) NOT approved"
        while IFS= read -r u; do
            [[ -z "$u" ]] && continue
            note "UNAUTHORIZED: $u"
            alert "Unauthorized model '$u' installed on $(hostname) - not on the district approved list"
        done <<< "$UNAUTHORIZED"
        note "Remove with: ollama rm <model>   (or add to $APPROVED_FILE after review)"
    fi

    # A model on the approved list that is missing is worth knowing about too -
    # a staff workflow that depends on it will fail.
    MISSING=""
    while IFS= read -r a; do
        [[ -z "$a" || "$a" == *:* ]] && continue
        printf '%s\n' "$INSTALLED" | grep -q "^${a}\(:\|$\)" || MISSING+="$a "
    done <<< "$APPROVED"
    [[ -n "$MISSING" ]] && note "Approved but not installed: ${MISSING% }"
fi

# ============================================================ 6. DISK
if [[ ! -d "$MODELS_DIR" ]]; then
    record SKIP "Model disk below ${THRESHOLD}%" "directory not found: $MODELS_DIR"
else
    read -r pct mount < <(df -P "$MODELS_DIR" 2>/dev/null | awk 'NR==2{print $5, $6}')
    num=${pct%\%}
    if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        record SKIP "Model disk below ${THRESHOLD}%" "could not read df output"
    else
        avail=$(df -Ph "$MODELS_DIR" 2>/dev/null | awk 'NR==2{print $4}')
        dirsz=$(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)
        detail="${pct} used on ${mount}, ${avail} free${dirsz:+, models occupy $dirsz}"
        if (( num >= 95 )); then
            record FAIL "Model disk below ${THRESHOLD}%" "$detail"
            alert "Model storage critically full on $(hostname): $pct"
        elif (( num > THRESHOLD )); then
            record WARN "Model disk below ${THRESHOLD}%" "$detail"
        else
            record PASS "Model disk below ${THRESHOLD}%" "$detail"
        fi
    fi
fi

# ============================================================ 7. JOURNAL
if [[ $HAS_SYSTEMD -eq 1 ]] && have journalctl; then
    JOUT=$(journalctl -u "$SERVICE" --since "${JOURNAL_HOURS} hour ago" --no-pager 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        record SKIP "No journal errors in last ${JOURNAL_HOURS}h" "journalctl unreadable (needs root)"
    elif [[ -z "$JOUT" ]]; then
        record PASS "No journal errors in last ${JOURNAL_HOURS}h" "no entries in the window"
    else
        ERRS=$(printf '%s\n' "$JOUT" | grep -iE 'level=error|"level":"error"|\berror\b|\bfatal\b|panic:' \
               | grep -viE 'error[_-]?(rate|count|handler)=0|no error' || true)
        n=$(printf '%s' "$ERRS" | grep -c '[^[:space:]]' || true)
        if [[ "${n:-0}" -eq 0 ]]; then
            record PASS "No journal errors in last ${JOURNAL_HOURS}h" "0 error lines"
        else
            record WARN "No journal errors in last ${JOURNAL_HOURS}h" "$n error line(s)"
            while IFS= read -r l; do
                [[ -n "$l" ]] && note "${l:0:110}"
            done < <(printf '%s\n' "$ERRS" | tail -n 3)
        fi
    fi
else
    record SKIP "No journal errors in last ${JOURNAL_HOURS}h" "journalctl unavailable"
fi

# ============================================================ VERDICT
if   (( N_FAIL > 0 ));  then VERDICT="CRITICAL"; VCOL=$RED; CODE=2
elif (( N_WARN > 0 ));  then VERDICT="WARNING";  VCOL=$YEL; CODE=1
elif (( N_PASS == 0 )); then VERDICT="UNKNOWN";  VCOL=$CYN; CODE=3
else                         VERDICT="HEALTHY";  VCOL=$GRN; CODE=0
fi

SUMMARY=$(printf '%d passed, %d warning, %d failed, %d skipped' "$N_PASS" "$N_WARN" "$N_FAIL" "$N_SKIP")

LOG+="========================================================================"$'\n'
LOG+="OVERALL: $VERDICT   ($SUMMARY)"$'\n'
if [[ ${#ALERTS[@]} -gt 0 ]]; then
    LOG+=""$'\n'
    LOG+="ALERTS REQUIRING ACTION:"$'\n'
    i=1
    for a in "${ALERTS[@]}"; do LOG+="  $i. $a"$'\n'; i=$((i+1)); done
fi
LOG+="========================================================================"$'\n'

if [[ $QUIET -eq 0 ]]; then
    printf '========================================================================\n'
    printf '  OVERALL: %b%s%b   (%s)\n' "$B$VCOL" "$VERDICT" "$R" "$SUMMARY"
    if [[ ${#ALERTS[@]} -gt 0 ]]; then
        printf '\n  %bALERTS REQUIRING ACTION:%b\n' "$B$RED" "$R"
        i=1
        for a in "${ALERTS[@]}"; do printf '    %d. %s\n' "$i" "$a"; i=$((i+1)); done
    fi
    printf '========================================================================\n'
else
    printf '%s (%s)\n' "$VERDICT" "$SUMMARY"
    for a in "${ALERTS[@]:-}"; do [[ -n "$a" ]] && printf '  ALERT: %s\n' "$a"; done
fi

if [[ -n "$OUTFILE" ]]; then
    if printf '%s' "$LOG" > "$OUTFILE" 2>/dev/null; then
        [[ $QUIET -eq 0 ]] && printf '\nReport written to: %s\n' "$OUTFILE"
    else
        printf 'Warning: could not write %s\n' "$OUTFILE" >&2
    fi
fi

# Mail only on a non-healthy result, so a cron entry does not spam the helpdesk.
if [[ -n "$MAILTO" && $CODE -ne 0 ]]; then
    if have mail; then
        printf '%s' "$LOG" | mail -s "[SVUSD] Ollama $VERDICT on $(hostname)" "$MAILTO"
    else
        printf 'Warning: mail command not available, cannot notify %s\n' "$MAILTO" >&2
    fi
fi

exit "$CODE"
