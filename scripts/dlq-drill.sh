#!/usr/bin/env bash
#
# Dead-letter drill: send a malformed message to the notify queue and watch
# it fail 5 times, land in the DLQ, and trigger the DLQ alarm - without
# blocking the good messages around it (partial batch responses).
# Takes ~5-6 minutes (5 receives x 60 s visibility timeout).

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_outputs

url() { aws sqs get-queue-url --queue-name "$1" --query QueueUrl --output text; }
depth() { aws sqs get-queue-attributes --queue-url "$1" --attribute-names ApproximateNumberOfMessages \
  --query Attributes.ApproximateNumberOfMessages --output text; }

Q="$(url "$NOTIFY_QUEUE")"; DLQ="$(url "$NOTIFY_DLQ")"
log "sending a poison message to $NOTIFY_QUEUE"
aws sqs send-message --queue-url "$Q" --message-body '{"detail": "this is not a timesheet event"}' >/dev/null

start=$(date +%s)
until [ "$(depth "$DLQ")" -ge 1 ]; do
  [ $(( $(date +%s) - start )) -gt 480 ] && { log "not in the DLQ after 8 minutes"; exit 1; }
  sleep 15
done
log "poison message reached $NOTIFY_DLQ after $(( $(date +%s) - start ))s"
log "alarm state: $(aws cloudwatch describe-alarms --alarm-name-prefix "${NOTIFY_DLQ%-notify-dlq}-dlq-notify" \
  --query 'MetricAlarms[0].StateValue' --output text)"

cat <<MSG

Operator next steps (docs/runbook.md#dead-letter-queues):
  1. Inspect:  aws sqs receive-message --queue-url $DLQ --attribute-names All --message-attribute-names All
  2. Poison?   delete it.   Transient failure?  redrive after the fix:
               aws sqs start-message-move-task --source-arn \$(aws sqs get-queue-attributes --queue-url $DLQ --attribute-names QueueArn --query Attributes.QueueArn --output text)
MSG
