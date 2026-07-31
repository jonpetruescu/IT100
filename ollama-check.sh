#!/usr/bin/env bash
#
# ollama-check.sh - Ollama health check with per-check PASS/FAIL output.
#
#   1. Ollama service running          (systemctl is-active ollama)
#   2. Bound to 127.0.0.1, not 0.0.0.0 (ss -tuln | grep 11434)
#   3. API responding                  (curl -s localhost:11434/api/tags)
#   4. Models installed                (ollama list | tail -n +2 | wc -l)
#   5. Model disk usage below 80% of its partition
#   6. No ERROR entries in the Ollama journal in the last hour
#
# Final verdict: HEALTHY / WARNING / CRITICAL
#
# Exit codes follow the Nagios convention so this drops into most monitoring
# systems unchanged:
#   0 = HEALTHY   1 = WARNING   2 = CRITICAL   3 = UNKNOWN (usage/env error)
#
# Usage:
#   ./ollama-check.sh [-t PCT] [-p PORT] [-H HOURS] [-o FILE] [-q] [-h]
#
#   -t PCT    disk threshold percentage (default 80)
#   -p PORT   Ollama port (default 11434)
#   -H HOURS  journal lookback window in hours (default 1)
#   -o FILE   also write the report to FILE
#   -q        quiet: print only the final verdict line
#   -h        show this help

set -uo pipefail

THRESHOLD=80
PORT=11434
JOURNAL_HOURS=1
OUTFILE=""
QUIET=0
SERVICE="ollama"
MODELS_DIR="${OLLAMA_MODELS:-$HOME/.ollama/models}"

usage() { sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ':t:p:H:o:qh' opt; do
    case "$opt" in
        t) THRESHOLD=$OPTARG ;;
        p) PORT=$OPTARG ;;
        H) JOURNAL_HOURS=$OPTARG ;;
        o) OUTFILE=$OPTARG ;;
        q) QUIET=1 ;;
        h) usage 0 ;;
        :)  printf 'Option -%s requires an argument.\n' "$OPTARG" >&2; usage 3 ;;
        \?) printf 'Unknown option: -%s\n' "$OPTARG" >&2; usage 3 ;;
    esac
done

[[ "$THRESHOLD" =~ ^[0-9]+$ && $THRESHOLD -ge 1 && $THRESHOLD -le 99 ]] || {
    printf 'Threshold must be an integer 1-99.\n' >&2; exit 3; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { printf 'Port must be numeric.\n' >&2; exit 3; }
[[ "$JOURNAL_HOURS" =~ ^[0-9]+$ ]] || { printf 'Hours must be numeric.\n' >&2; exit 3; }

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ colours
if [[ -t 1 ]] && have tput && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    R=$(tput sgr0); B=$(tput bold)
    RED=$(tput setaf 1); GRN=$(tput setaf 2); YEL=$(tput setaf 3); CYN=$(tput setaf 6)
else
    R=""; B=""; RED=""; GRN=""; YEL=""; CYN=""
fi

# ------------------------------------------------------------------ results
N_PASS=0; N_WARN=0; N_FAIL=0; N_SKIP=0
LOG=""

# record <status> <label> <detail>
#   PASS - check satisfied
#   WARN - degraded, contributes to WARNING
#   FAIL - broken, forces CRITICAL
#   SKIP - could not be determined; never masks a real result as PASS
record() {
    local status="$1" label="$2" detail="${3:-}" colour tag
    case "$status" in
        PASS) colour=$GRN; ((N_PASS++)) ;;
        WARN) colour=$YEL; ((N_WARN++)) ;;
        FAIL) colour=$RED; ((N_FAIL++)) ;;
        SKIP) colour=$CYN; ((N_SKIP++)) ;;
    esac
    tag=$(printf '[ %-4s ]' "$status")
    # Same field widths as the console line so the file and terminal align.
    LOG+=$(printf '%s %-34s %s' "$tag" "$label" "$detail")$'\n'
    [[ $QUIET -eq 1 ]] && return 0
    printf '%b%s%b %-34s %s\n' "$colour" "$tag" "$R" "$label" "$detail"
}

note() {
    LOG+="           $*"$'\n'
    [[ $QUIET -eq 1 ]] || printf '           %s\n' "$*"
}

if [[ $QUIET -eq 0 ]]; then
    printf '%b' "$B"
    printf '========================================================================\n'
    printf '  OLLAMA HEALTH CHECK - %s - %s\n' "$(hostname -s 2>/dev/null || hostname)" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '========================================================================\n'
    printf '%b' "$R"
fi
LOG+="OLLAMA HEALTH CHECK - $(hostname 2>/dev/null) - $(date '+%Y-%m-%d %H:%M:%S %Z')"$'\n'
LOG+="========================================================================"$'\n'

HAS_SYSTEMD=0
if have systemctl && [[ -d /run/systemd/system ]]; then HAS_SYSTEMD=1; fi

# ============================================================ 1. SERVICE
SERVICE_UP=0
if [[ $HAS_SYSTEMD -eq 1 ]] && systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE}\.service"; then
    state=$(systemctl is-active "$SERVICE" 2>/dev/null)
    if [[ "$state" == "active" ]]; then
        SERVICE_UP=1
        since=$(systemctl show "$SERVICE" -p ActiveEnterTimestamp --value 2>/dev/null)
        record PASS "Ollama service running" "active${since:+ since $since}"
    else
        record FAIL "Ollama service running" "systemctl reports: ${state:-unknown}"
    fi
elif pgrep -x ollama >/dev/null 2>&1; then
    # No unit file, but the daemon is up - a manual `ollama serve` counts.
    SERVICE_UP=1
    record PASS "Ollama service running" "process up (pid $(pgrep -x ollama | head -1)), no systemd unit"
else
    if [[ $HAS_SYSTEMD -eq 0 ]]; then
        record FAIL "Ollama service running" "no systemd and no ollama process found"
    else
        record FAIL "Ollama service running" "no ollama.service unit and no ollama process"
    fi
fi

# ============================================================ 2. BIND ADDRESS
LISTEN=""
if have ss; then
    LISTEN=$(ss -tuln 2>/dev/null | awk -v p=":$PORT" '$5 ~ p"$" {print $5}')
elif have netstat; then
    LISTEN=$(netstat -tuln 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {print $4}')
elif have lsof; then
    LISTEN=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}')
fi

if [[ -z "$LISTEN" ]]; then
    if [[ $SERVICE_UP -eq 1 ]]; then
        record FAIL "Bound to 127.0.0.1 (not 0.0.0.0)" "service up but nothing listening on :$PORT"
    else
        record SKIP "Bound to 127.0.0.1 (not 0.0.0.0)" "no listener on :$PORT (service is down)"
    fi
else
    EXPOSED=0; LOOPBACK=0
    while IFS= read -r ep; do
        [[ -z "$ep" ]] && continue
        a=${ep%:*}; a=${a#[}; a=${a%]}
        case "$a" in
            127.0.0.1|::1|localhost) LOOPBACK=1 ;;
            0.0.0.0|::|'*')          EXPOSED=1; EXPOSED_EP=$ep ;;
            *)                       EXPOSED=1; EXPOSED_EP=$ep ;;
        esac
    done <<< "$LISTEN"

    if [[ $EXPOSED -eq 1 ]]; then
        record FAIL "Bound to 127.0.0.1 (not 0.0.0.0)" "listening on ${EXPOSED_EP} - reachable from the network"
        note "Ollama has no authentication: anyone who can reach this port can"
        note "run inference, pull models, and delete them."
        note "Fix: Environment=\"OLLAMA_HOST=127.0.0.1:$PORT\" in the unit, then restart."
    elif [[ $LOOPBACK -eq 1 ]]; then
        record PASS "Bound to 127.0.0.1 (not 0.0.0.0)" "loopback only ($(printf '%s' "$LISTEN" | tr '\n' ' '))"
    else
        record WARN "Bound to 127.0.0.1 (not 0.0.0.0)" "unrecognised bind address: $LISTEN"
    fi
fi

# ============================================================ 3. API
MODEL_JSON=""
if have curl; then
    MODEL_JSON=$(curl -fsS --max-time 5 "http://localhost:${PORT}/api/tags" 2>/dev/null)
    rc=$?
    if [[ $rc -eq 0 && -n "$MODEL_JSON" ]]; then
        # Tolerate whitespace after the colon - not all JSON encoders emit compact output.
        ver=$(curl -fsS --max-time 5 "http://localhost:${PORT}/api/version" 2>/dev/null \
              | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/')
        record PASS "API responding" "/api/tags returned 200${ver:+, version $ver}"
    else
        record FAIL "API responding" "no valid response from localhost:${PORT}/api/tags (curl rc=$rc)"
    fi
elif have wget; then
    MODEL_JSON=$(wget -qO- -T 5 "http://localhost:${PORT}/api/tags" 2>/dev/null)
    if [[ -n "$MODEL_JSON" ]]; then
        record PASS "API responding" "/api/tags returned data (via wget)"
    else
        record FAIL "API responding" "no response from localhost:${PORT}/api/tags"
    fi
else
    record SKIP "API responding" "neither curl nor wget is installed"
fi

# ============================================================ 4. MODEL COUNT
COUNT=""
if have ollama; then
    # `ollama list` needs a reachable server; suppress its error noise.
    COUNT=$(ollama list 2>/dev/null | tail -n +2 | grep -c '[^[:space:]]')
fi
# Fall back to counting objects in the API response if the CLI is unavailable.
if [[ -z "$COUNT" || "$COUNT" == "0" ]] && [[ -n "$MODEL_JSON" ]]; then
    api_count=$(printf '%s' "$MODEL_JSON" | grep -o '"name"' | wc -l | tr -d ' ')
    [[ "$api_count" =~ ^[0-9]+$ && $api_count -gt 0 ]] && COUNT=$api_count
fi

if [[ -z "$COUNT" ]]; then
    record SKIP "Models installed" "cannot determine (ollama CLI and API both unavailable)"
elif [[ "$COUNT" -eq 0 ]]; then
    record WARN "Models installed" "0 models present - nothing can be served"
else
    # paste -sd', ' cycles through the delimiter LIST (',' then ' '), so it
    # joins inconsistently. Build the separator explicitly instead.
    names=$(ollama list 2>/dev/null | tail -n +2 | awk 'NF{printf "%s%s", sep, $1; sep=", "}')
    record PASS "Models installed" "$COUNT model(s)"
    [[ -n "$names" && ${#names} -lt 200 ]] && note "$names"
fi

# ============================================================ 5. DISK
if [[ ! -d "$MODELS_DIR" ]]; then
    record SKIP "Model disk below ${THRESHOLD}%" "directory not found: $MODELS_DIR"
else
    read -r pct mount < <(df -P "$MODELS_DIR" 2>/dev/null | awk 'NR==2 {print $5, $6}')
    num=${pct%\%}
    if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        record SKIP "Model disk below ${THRESHOLD}%" "could not read df output for $MODELS_DIR"
    else
        avail=$(df -Ph "$MODELS_DIR" 2>/dev/null | awk 'NR==2{print $4}')
        dirsz=$(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)
        detail="${pct} used on ${mount}, ${avail} free${dirsz:+, models occupy $dirsz}"
        if (( num >= 95 )); then
            # Near-full is not a soft warning: pulls and writes will fail.
            record FAIL "Model disk below ${THRESHOLD}%" "$detail"
        elif (( num > THRESHOLD )); then
            record WARN "Model disk below ${THRESHOLD}%" "$detail"
            note "Reclaim space with: ollama list, then ollama rm <model>"
        else
            record PASS "Model disk below ${THRESHOLD}%" "$detail"
        fi
    fi
fi

# ============================================================ 6. JOURNAL
if [[ $HAS_SYSTEMD -eq 1 ]] && have journalctl; then
    JOUT=$(journalctl -u "$SERVICE" --since "${JOURNAL_HOURS} hour ago" --no-pager 2>/dev/null)
    jrc=$?
    if [[ $jrc -ne 0 ]]; then
        record SKIP "No journal ERRORs in last ${JOURNAL_HOURS}h" "journalctl unreadable (try sudo, or add user to systemd-journal)"
    elif [[ -z "$JOUT" ]]; then
        record PASS "No journal ERRORs in last ${JOURNAL_HOURS}h" "no journal entries in the window"
    else
        # Match both priority-tagged errors and Ollama's plain-text error lines.
        ERRS=$(printf '%s\n' "$JOUT" | grep -iE 'level=error|"level":"error"|\berror\b|\bfatal\b|panic:' \
               | grep -viE 'error[_-]?(rate|count|handler)=0|no error' || true)
        n=$(printf '%s' "$ERRS" | grep -c '[^[:space:]]' || true)
        if [[ "${n:-0}" -eq 0 ]]; then
            record PASS "No journal ERRORs in last ${JOURNAL_HOURS}h" "0 error lines in $(printf '%s\n' "$JOUT" | wc -l | tr -d ' ') entries"
        else
            record WARN "No journal ERRORs in last ${JOURNAL_HOURS}h" "$n error line(s) found"
            while IFS= read -r l; do
                [[ -z "$l" ]] && continue
                note "${l:0:120}"
            done < <(printf '%s\n' "$ERRS" | tail -n 3)
        fi
    fi
elif have journalctl; then
    record SKIP "No journal ERRORs in last ${JOURNAL_HOURS}h" "systemd not running on this host"
else
    record SKIP "No journal ERRORs in last ${JOURNAL_HOURS}h" "journalctl not available"
fi

# ============================================================ VERDICT
if   (( N_FAIL > 0 )); then VERDICT="CRITICAL"; VCOL=$RED; CODE=2
elif (( N_WARN > 0 )); then VERDICT="WARNING";  VCOL=$YEL; CODE=1
elif (( N_PASS == 0 )); then VERDICT="UNKNOWN"; VCOL=$CYN; CODE=3
else VERDICT="HEALTHY"; VCOL=$GRN; CODE=0
fi

SUMMARY_LINE=$(printf '%d passed, %d warning, %d failed, %d skipped' \
    "$N_PASS" "$N_WARN" "$N_FAIL" "$N_SKIP")

LOG+="========================================================================"$'\n'
LOG+="OVERALL: $VERDICT   ($SUMMARY_LINE)"$'\n'
LOG+="========================================================================"$'\n'

if [[ $QUIET -eq 0 ]]; then
    printf '========================================================================\n'
    printf '  OVERALL: %b%s%b   (%s)\n' "$B$VCOL" "$VERDICT" "$R" "$SUMMARY_LINE"
    printf '========================================================================\n'
else
    printf '%s (%s)\n' "$VERDICT" "$SUMMARY_LINE"
fi

if [[ -n "$OUTFILE" ]]; then
    if printf '%s' "$LOG" > "$OUTFILE" 2>/dev/null; then
        [[ $QUIET -eq 0 ]] && printf '\nReport written to: %s\n' "$OUTFILE"
    else
        printf 'Warning: could not write report to %s\n' "$OUTFILE" >&2
    fi
fi

exit "$CODE"
