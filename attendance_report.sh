#!/bin/bash
#
# attendance_report.sh - Calculate late arrivals & early departures
# from a ZKTeco WDMS "Transaction" CSV export.
#
# Usage:
#   ./attendance_report.sh <export.csv> [start_date] [end_date] [arrival_time] [departure_time] [grace_minutes]
#
# Examples:
#   ./attendance_report.sh export.csv
#       -> uses today's date, 09:00 arrival, 18:00 departure, 180 min grace
#
#   ./attendance_report.sh export.csv 2026-07-30 2026-07-30
#       -> report for just 2026-07-30
#
#   ./attendance_report.sh export.csv 2026-07-01 2026-07-30 09:00:00 18:00:00 180
#       -> report for the whole month, custom shift times, 180 min grace allowance
#
# "Grace minutes" is the total (late-arrival + early-leave) time each employee
# is allowed before they exceed their allowance. Default is 180 minutes.
#
# Expects a CSV with (at least) these header columns, in any order:
#   PIN, EName (or Name), Time, State
# "Time" must contain "YYYY-MM-DD HH:MM:SS" and "State" must contain
# "Check In" / "Check Out" (case-insensitive, matched on the word "out").
#
# Assumes ONE check-in and ONE check-out per person per day. If there are
# multiple punches, the earliest is used as check-in and the latest as
# check-out.

set -euo pipefail

CSV_FILE="${1:?Usage: $0 <export.csv> [start_date] [end_date] [arrival_time] [departure_time] [grace_minutes]}"
START_DATE="${2:-$(date +%F)}"
END_DATE="${3:-$START_DATE}"
ARRIVAL_TIME="${4:-09:00:00}"
DEPARTURE_TIME="${5:-18:00:00}"
GRACE_MINUTES="${6:-180}"
GRACE_SEC=$(( GRACE_MINUTES * 60 ))

if [[ ! -f "$CSV_FILE" ]]; then
    echo "Error: file not found: $CSV_FILE" >&2
    exit 1
fi

TMP_NORMALIZED=$(mktemp)
ROWS_FILE=$(mktemp)
trap 'rm -f "$TMP_NORMALIZED" "$ROWS_FILE"' EXIT

# --- Step 1: normalize the CSV into date|pin|name|state|time -----------
awk -F',' -v OFS='|' '
function trim(x) {
    gsub(/"/,"",x)
    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/,"",x)
    return x
}
{
    # strip UTF-8 BOM (only present on very first line) and trailing CR
    if (NR==1) sub(/^\xef\xbb\xbf/,"")
    sub(/\r$/,"")
}
NR==1 {
    for (i=1;i<=NF;i++) {
        h=tolower(trim($i))
        if (h=="pin")                 pin_c=i
        if (h=="ename" || h=="name")  name_c=i
        if (h=="time")                time_c=i
        if (h=="state")               state_c=i
    }
    if (!pin_c || !name_c || !time_c || !state_c) {
        print "ERROR: could not find required columns (PIN, EName, Time, State) in header" > "/dev/stderr"
        exit 1
    }
    next
}
{
    pin=trim($pin_c); name=trim($name_c); t=trim($time_c); st=trim($state_c)
    if (t=="") next
    split(t, dt, " ")
    d=dt[1]; tm=dt[2]
    if (d=="" || tm=="") next
    print d, pin, name, st, tm
}
' "$CSV_FILE" > "$TMP_NORMALIZED"

# --- Step 2: fold into first check-in / last check-out per person/day --
declare -A CHECKIN
declare -A CHECKOUT
declare -A NAME_OF

while IFS='|' read -r d pin name st tm; do
    [[ -z "${d:-}" ]] && continue
    [[ "$d" < "$START_DATE" || "$d" > "$END_DATE" ]] && continue

    key="${d}|${pin}"
    NAME_OF["$key"]="$name"

    stl=$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')
    if [[ "$stl" == *out* ]]; then
        if [[ -z "${CHECKOUT[$key]:-}" || "$tm" > "${CHECKOUT[$key]}" ]]; then
            CHECKOUT["$key"]="$tm"
        fi
    else
        if [[ -z "${CHECKIN[$key]:-}" || "$tm" < "${CHECKIN[$key]}" ]]; then
            CHECKIN["$key"]="$tm"
        fi
    fi
done < "$TMP_NORMALIZED"

if [[ ${#CHECKIN[@]} -eq 0 ]]; then
    echo "No check-in records found between $START_DATE and $END_DATE." >&2
    exit 0
fi

# --- Step 3: compute late-by / early-by per person/day ------------------
TOTAL_LATE=0
TOTAL_EARLY=0
LATE_COUNT=0
EARLY_COUNT=0
NO_CHECKOUT_COUNT=0

declare -A EMP_LATE
declare -A EMP_EARLY
declare -A EMP_NAME

for key in "${!CHECKIN[@]}"; do
    d="${key%%|*}"
    pin="${key##*|}"
    name="${NAME_OF[$key]}"
    ci="${CHECKIN[$key]}"
    co="${CHECKOUT[$key]:-}"

    arr_epoch=$(date -d "$d $ARRIVAL_TIME" +%s)
    ci_epoch=$(date -d "$d $ci" +%s)
    late_sec=$(( ci_epoch - arr_epoch ))
    if (( late_sec > 0 )); then
        late_str=$(printf '%dh %dm' $((late_sec/3600)) $(((late_sec%3600)/60)))
        TOTAL_LATE=$(( TOTAL_LATE + late_sec ))
        LATE_COUNT=$(( LATE_COUNT + 1 ))
    else
        late_sec=0
        late_str="On time"
    fi

    early_sec=0
    if [[ -n "$co" ]]; then
        dep_epoch=$(date -d "$d $DEPARTURE_TIME" +%s)
        co_epoch=$(date -d "$d $co" +%s)
        early_sec=$(( dep_epoch - co_epoch ))
        if (( early_sec > 0 )); then
            early_str=$(printf '%dh %dm' $((early_sec/3600)) $(((early_sec%3600)/60)))
            TOTAL_EARLY=$(( TOTAL_EARLY + early_sec ))
            EARLY_COUNT=$(( EARLY_COUNT + 1 ))
        else
            early_sec=0
            early_str="On time"
        fi
    else
        co="--"
        early_str="N/A"
        NO_CHECKOUT_COUNT=$(( NO_CHECKOUT_COUNT + 1 ))
    fi

    ekey="${pin}|${name}"
    EMP_NAME["$ekey"]="$name"
    EMP_LATE["$ekey"]=$(( ${EMP_LATE[$ekey]:-0} + late_sec ))
    EMP_EARLY["$ekey"]=$(( ${EMP_EARLY[$ekey]:-0} + early_sec ))

    printf "%-12s %-10s %-22.22s %-10s %-10s %-15s %-15s\n" \
        "$d" "$pin" "$name" "$ci" "$co" "$late_str" "$early_str" >> "$ROWS_FILE"
done

# --- Step 4: print report -----------------------------------------------
echo "Attendance Report: $START_DATE to $END_DATE  (Shift: $ARRIVAL_TIME - $DEPARTURE_TIME)"
echo "=================================================================================="
printf "%-12s %-10s %-22s %-10s %-10s %-15s %-15s\n" \
    "Date" "PIN" "Name" "CheckIn" "CheckOut" "Late By" "Left Early By"
printf '%s\n' "----------------------------------------------------------------------------------"
sort "$ROWS_FILE"

TOTAL_EXCEEDED=$(( TOTAL_LATE + TOTAL_EARLY ))
GRACE_DIFF=$(( GRACE_SEC - TOTAL_EXCEEDED ))

echo ""
echo "Summary"
echo "-------"
echo "  Employees late       : $LATE_COUNT"
echo "  Employees left early : $EARLY_COUNT"
echo "  Missing check-out    : $NO_CHECKOUT_COUNT"
printf "  Total late time      : %dh %dm\n"  $((TOTAL_LATE/3600))  $(((TOTAL_LATE%3600)/60))
printf "  Total early-leave time: %dh %dm\n" $((TOTAL_EARLY/3600)) $(((TOTAL_EARLY%3600)/60))
printf "  Total time exceeded  : %dh %dm\n" $((TOTAL_EXCEEDED/3600)) $(((TOTAL_EXCEEDED%3600)/60))
if (( GRACE_DIFF >= 0 )); then
    printf "  Total grace left     : %dh %dm (of %dh %dm allowed)\n" \
        $((GRACE_DIFF/3600)) $(((GRACE_DIFF%3600)/60)) $((GRACE_SEC/3600)) $(((GRACE_SEC%3600)/60))
else
    ABS_OVER=$(( -GRACE_DIFF ))
    printf "  Total grace left     : EXCEEDED by %dh %dm (allowance was %dh %dm)\n" \
        $((ABS_OVER/3600)) $(((ABS_OVER%3600)/60)) $((GRACE_SEC/3600)) $(((GRACE_SEC%3600)/60))
fi

# --- Per-employee grace breakdown (useful when the file covers several people) ---
if [[ ${#EMP_LATE[@]} -gt 1 ]]; then
    echo ""
    echo "Per-Employee Grace Summary (allowance: ${GRACE_MINUTES}m each)"
    echo "-------------------------------------------------------------"
    printf "%-10s %-22s %-12s %-12s %-14s %-16s\n" \
        "PIN" "Name" "Late" "Early" "Exceeded" "Grace Left"
    for ekey in "${!EMP_LATE[@]}"; do
        pin="${ekey%%|*}"
        name="${EMP_NAME[$ekey]}"
        elate="${EMP_LATE[$ekey]}"
        eearly="${EMP_EARLY[$ekey]}"
        eexceed=$(( elate + eearly ))
        ediff=$(( GRACE_SEC - eexceed ))
        if (( ediff >= 0 )); then
            gstr=$(printf '%dh %dm left' $((ediff/3600)) $(((ediff%3600)/60)))
        else
            eover=$(( -ediff ))
            gstr=$(printf 'EXCEEDED %dh %dm' $((eover/3600)) $(((eover%3600)/60)))
        fi
        printf "%-10s %-22.22s %-12s %-12s %-14s %-16s\n" \
            "$pin" "$name" \
            "$(printf '%dh %dm' $((elate/3600)) $(((elate%3600)/60)))" \
            "$(printf '%dh %dm' $((eearly/3600)) $(((eearly%3600)/60)))" \
            "$(printf '%dh %dm' $((eexceed/3600)) $(((eexceed%3600)/60)))" \
            "$gstr"
    done | sort
fi
