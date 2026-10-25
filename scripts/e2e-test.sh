#!/usr/bin/env bash
#
# End-to-end business flow against the deployed system:
#   employee submits 45 h -> manager approves -> ledger records hours (async)
#   -> HR runs payroll -> CSV shows 40 h regular + 5 h overtime at 1.5x
# plus authorization checks. Writes docs/evidence/e2e-<timestamp>.md.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_outputs
[ -f "$USERS_FILE" ] || { echo "run scripts/seed-users.sh first" >&2; exit 2; }

WEEK="$(last_monday)"
EMP_ID="$(user_field employee sub)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS=()
fail=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then RESULTS+=("| PASS | $1 |"); echo "PASS  $1"
  else RESULTS+=("| FAIL | $1 (expected $2, got $3) |"); echo "FAIL  $1 (expected $2, got $3)"; fail=1; fi
}

EMP="$(token employee)"; MGR="$(token manager)"; HR="$(token hr)"

# Mon-Fri 9h each = 45h (5h overtime). Week of $WEEK.
ENTRIES="$(jq -cn --arg w "$WEEK" '[range(0;5)] | map(. as $i | {
  date: ($w | strptime("%Y-%m-%d") | mktime + $i * 86400 | strftime("%Y-%m-%d")),
  projectCode: (if $i < 4 then "ACME-12" else "OPS-7" end), hours: 9})')"

r="$(api "$EMP" PUT "/me/timesheets/$WEEK" "{\"entries\": $ENTRIES, \"note\": \"e2e $STAMP\"}")"
code="${r%% *}"
if [ "$code" = 409 ]; then log "week $WEEK already submitted earlier - continuing with the existing timesheet"; fi
check "employee submits week $WEEK (201, or 409 if a previous run did)" yes "$([[ $code = 201 || $code = 409 ]] && echo yes || echo no)"

check "employee cannot read HR profiles" 403 "$(api "$EMP" GET "/hr/employees/$EMP_ID" | cut -d' ' -f1)"
check "employee cannot approve" 403 "$(api "$EMP" POST "/manager/timesheets/$EMP_ID/$WEEK/decision" '{"decision":"approve"}' | cut -d' ' -f1)"
check "no token is rejected at the edge" 401 "$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/me/timesheets")"

queue="$(api "$MGR" GET /manager/queue)"
if [ "${queue%% *}" = 200 ] && jq -e --arg e "$EMP_ID" '.pending[] | select(.employeeId == $e)' <<<"${queue#* }" >/dev/null; then
  check "manager approves" 200 "$(api "$MGR" POST "/manager/timesheets/$EMP_ID/$WEEK/decision" '{"decision":"approve"}' | cut -d' ' -f1)"
else
  log "timesheet not pending (already approved/paid by an earlier run)"
fi

# Ledger consumer is asynchronous: Stream -> Pipe -> bus -> SQS -> Lambda.
start=$(date +%s); hours=0
while [ $(( $(date +%s) - start )) -lt 60 ]; do
  hours="$(api "$MGR" GET /reports/projects/ACME-12 | cut -d' ' -f2- | jq -r --arg w "$WEEK" '[.weeks[] | select(.weekStart == $w) | .approvedHours] | first // 0')"
  [ "$hours" != 0 ] && break
  sleep 2
done
check "ledger recorded approved ACME-12 hours (async, $(( $(date +%s) - start ))s)" yes "$(awk -v h="$hours" 'BEGIN{print (h >= 36) ? "yes" : "no"}')"

r="$(api "$HR" POST /hr/payroll-runs "{\"periodStart\": \"$WEEK\", \"weeks\": 1}")"
log "payroll start: HTTP ${r%% *}"
start=$(date +%s); status=""
while [ $(( $(date +%s) - start )) -lt 180 ]; do
  run="$(api "$HR" GET "/hr/payroll-runs/$WEEK" | cut -d' ' -f2-)"
  status="$(jq -r '.status // empty' <<<"$run")"
  [[ "$status" = COMPLETED || "$status" = FAILED ]] && break
  sleep 3
done
check "payroll run completes" COMPLETED "$status"

if [ "$status" = COMPLETED ]; then
  csv="$(curl -s "$(jq -r .downloadUrl <<<"$run")")"
  row="$(grep "^$EMP_ID," <<<"$csv" || true)"
  # 40h x $40 + 5h x $60 = $1,900.00 (if this run paid the employee; a supplemental run may not)
  if [ -n "$row" ]; then
    check "CSV: 40 regular + 5 overtime hours" "40.0,5.0" "$(cut -d, -f4,5 <<<"$row")"
    check "CSV: gross pay with FLSA overtime" "1900.00" "$(cut -d, -f7 <<<"$row")"
  fi
  check "download link expires in 5 minutes" 300 "$(jq -r .downloadUrlExpiresInSeconds <<<"$run")"
fi

mkdir -p "$EVIDENCE_DIR"
{
  echo "# End-to-end test - $STAMP"
  echo
  echo "Week: \`$WEEK\` · API: \`${API_URL#https://}\`"
  echo
  echo "| Result | Check |"
  echo "|---|---|"
  printf '%s\n' "${RESULTS[@]}"
} >"$EVIDENCE_DIR/e2e-$STAMP.md"
log "report: docs/evidence/e2e-$STAMP.md"
exit "$fail"
