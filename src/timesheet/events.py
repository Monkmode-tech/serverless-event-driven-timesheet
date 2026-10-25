"""Event consumers (SQS -> Lambda, partial-batch responses).

Events originate as DynamoDB Stream records. An EventBridge Pipe turns each
timesheet change into a `TimesheetStatusChanged` event on the custom bus (a
transactional outbox: the event exists if and only if the write committed).
Bus rules route events to one SQS queue per consumer, each with a DLQ.

Delivery is at-least-once at every hop, so every consumer is idempotent on
(employeeId, weekStart, version) - one version per status change.
"""

from __future__ import annotations

import json
import os
import time
from collections import defaultdict
from typing import Any

from timesheet import domain
from timesheet.common import client, log, metric, table

IDEMPOTENCY_TTL_SECONDS = 30 * 24 * 3600


def parse_detail(record: dict[str, Any]) -> dict[str, Any]:
    """SQS body = the EventBridge event; its detail was shaped by the Pipe's input template."""
    event = json.loads(record["body"])
    detail = event["detail"]
    required = ("employeeId", "weekStart", "status", "version")
    if not all(detail.get(k) for k in required):
        raise ValueError(f"event missing one of {required}")
    detail["version"] = int(detail["version"])
    return detail


def idempotency_key(consumer: str, detail: dict[str, Any]) -> dict[str, Any]:
    return {
        "PK": f"IDEMPOTENCY#{consumer}",
        "SK": f"{detail['employeeId']}#{detail['weekStart']}#v{detail['version']}",
    }


def batch(records: list[dict[str, Any]], process) -> dict[str, Any]:
    """Process each message independently; only failed ones go back to the queue (and, after
    maxReceiveCount attempts, to the DLQ)."""
    failures = []
    for record in records:
        try:
            process(record)
        except Exception as exc:  # noqa: BLE001 - one bad message must not fail the batch
            log(40, "message failed", messageId=record.get("messageId"), error=type(exc).__name__, detail=str(exc))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}


# ---------------------------------------------------------------------------
# Notifier: tells the manager a timesheet is waiting, and the employee the outcome.
# At-least-once: a rare duplicate notification is acceptable; a lost one is not,
# so the "already sent" marker is written only after the publish succeeds.
# ---------------------------------------------------------------------------
def notification_for(detail: dict[str, Any]) -> tuple[str, str, str] | None:
    """(recipientUserId, subject, message) - IDs only, no names or hours in notifications."""
    week, emp = detail["weekStart"], detail["employeeId"]
    status = detail["status"]
    if status == domain.SUBMITTED:
        return detail.get("managerId", ""), "Timesheet awaiting approval", f"Employee {emp} submitted week {week}."
    if status == domain.APPROVED:
        return emp, "Timesheet approved", f"Your timesheet for week {week} was approved."
    if status == domain.REJECTED:
        return emp, "Timesheet returned", f"Your timesheet for week {week} needs changes - see the reason in the app."
    return None


def notify_handler(event: dict[str, Any], context: Any = None, tbl: Any = None, sns: Any = None):
    tbl = tbl if tbl is not None else table()
    sns = sns if sns is not None else client("sns")

    def process(record: dict[str, Any]) -> None:
        detail = parse_detail(record)
        key = idempotency_key("notify", detail)
        if tbl.get_item(Key=key, ConsistentRead=True).get("Item"):
            log(20, "duplicate event skipped", consumer="notify", **key)
            return
        note = notification_for(detail)
        if note:
            recipient, subject, message = note
            sns.publish(
                TopicArn=os.environ["NOTIFICATIONS_TOPIC_ARN"],
                Subject=subject,
                Message=message,
                MessageAttributes={"recipient": {"DataType": "String", "StringValue": recipient or "unknown"}},
            )
            metric("NotificationSent", 1, status=detail["status"])
        tbl.put_item(Item={**key, "expiresAt": int(time.time()) + IDEMPOTENCY_TTL_SECONDS})

    return batch(event.get("Records", []), process)


# ---------------------------------------------------------------------------
# Project-hours ledger: adds approved hours to per-project weekly totals.
# ADD is not idempotent, so the marker and the increments commit in ONE
# DynamoDB transaction: either both happen or neither does.
# ---------------------------------------------------------------------------
def project_totals(entries: list[dict[str, Any]]) -> dict[str, int]:
    totals: dict[str, int] = defaultdict(int)
    for e in entries:
        totals[str(e["projectCode"])] += int(e["quarterHours"])
    return dict(totals)


def ledger_transaction(table_name: str, detail: dict[str, Any], totals: dict[str, int]) -> list[dict[str, Any]]:
    key = idempotency_key("ledger", detail)
    items: list[dict[str, Any]] = [
        {
            "Put": {
                "TableName": table_name,
                "Item": {
                    "PK": {"S": key["PK"]},
                    "SK": {"S": key["SK"]},
                    "expiresAt": {"N": str(int(time.time()) + IDEMPOTENCY_TTL_SECONDS)},
                },
                "ConditionExpression": "attribute_not_exists(PK)",
            }
        }
    ]
    for code, qh in sorted(totals.items()):
        items.append(
            {
                "Update": {
                    "TableName": table_name,
                    "Key": {"PK": {"S": f"PROJECT#{code}"}, "SK": {"S": f"WEEK#{detail['weekStart']}"}},
                    "UpdateExpression": "ADD quarterHours :qh, approvedTimesheets :one",
                    "ExpressionAttributeValues": {":qh": {"N": str(qh)}, ":one": {"N": "1"}},
                }
            }
        )
    if len(items) > 100:
        raise ValueError("too many projects in one timesheet for a single transaction")
    return items


def is_duplicate(exc: Exception) -> bool:
    """TransactionCanceled because the idempotency marker (first item) already exists."""
    err = getattr(exc, "response", {})
    if err.get("Error", {}).get("Code") != "TransactionCanceledException":
        return False
    reasons = err.get("CancellationReasons") or []
    return bool(reasons) and reasons[0].get("Code") == "ConditionalCheckFailed"


def ledger_handler(event: dict[str, Any], context: Any = None, tbl: Any = None, ddb: Any = None):
    tbl = tbl if tbl is not None else table()
    ddb = ddb if ddb is not None else client("dynamodb")

    def process(record: dict[str, Any]) -> None:
        detail = parse_detail(record)
        if detail["status"] != domain.APPROVED:
            return  # the bus rule already filters; defensive
        item = tbl.get_item(
            Key={"PK": domain.employee_pk(detail["employeeId"]), "SK": domain.week_sk(detail["weekStart"])},
            ConsistentRead=True,
        ).get("Item")
        if not item:
            raise ValueError("timesheet in event no longer exists")
        totals = project_totals(item.get("entries", []))
        try:
            ddb.transact_write_items(TransactItems=ledger_transaction(os.environ["TABLE_NAME"], detail, totals))
        except Exception as exc:
            if is_duplicate(exc):
                log(20, "duplicate event skipped", consumer="ledger", employeeId=detail["employeeId"])
                metric("DuplicateEventSkipped", 1, consumer="ledger")
                return
            raise
        metric("ApprovedHoursRecorded", sum(totals.values()) / 4, "None")

    return batch(event.get("Records", []), process)
