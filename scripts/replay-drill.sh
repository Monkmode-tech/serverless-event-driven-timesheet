#!/usr/bin/env bash
#
# Replay drill: replay the last hour of archived events into the bus.
# Every consumer receives every event a second time. Because consumers are
# idempotent, project hour totals must NOT change, and the
# DuplicateEventSkipped metric goes up instead.

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_outputs
[ -f "$USERS_FILE" ] || { echo "run scripts/seed-users.sh first" >&2; exit 2; }

MGR="$(token manager)"
before="$(api "$MGR" GET /reports/projects/ACME-12 | cut -d' ' -f2- | jq -c .weeks)"
ARCHIVE_ARN="$(aws events describe-archive --archive-name "$ARCHIVE" --query ArchiveArn --output text)"
BUS_ARN="$(aws events describe-event-bus --name "$BUS" --query Arn --output text)"
NAME="replay-$(date -u +%Y%m%d%H%M%S)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START="$(date -u -d '-60 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-60M +%Y-%m-%dT%H:%M:%SZ)"

log "replaying $START .. $END from $ARCHIVE"
aws events start-replay --replay-name "$NAME" --event-source-arn "$ARCHIVE_ARN" \
  --event-start-time "$START" --event-end-time "$END" \
  --destination "{\"Arn\": \"$BUS_ARN\"}" >/dev/null
until [[ "$(aws events describe-replay --replay-name "$NAME" --query State --output text)" =~ COMPLETED|FAILED|CANCELLED ]]; do
  sleep 10
done
log "replay $(aws events describe-replay --replay-name "$NAME" --query State --output text); letting consumers drain"
sleep 60

after="$(api "$MGR" GET /reports/projects/ACME-12 | cut -d' ' -f2- | jq -c .weeks)"
if [ "$before" = "$after" ]; then
  echo "PASS  project totals unchanged after replaying every event (idempotent consumers)"
else
  echo "FAIL  totals changed: before=$before after=$after"; exit 1
fi
