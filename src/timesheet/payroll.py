"""Payroll workflow tasks, called by the Step Functions state machine.

The state machine carries only IDs and totals. Names and pay rates stay in
DynamoDB and the encrypted export, never in execution history.

    Collect -> (nothing to pay? stop) -> Lock -> Map(Calculate) -> Export
            -> Map(MarkPaid, direct DynamoDB) -> Close -> PayrollCompleted event
"""

from __future__ import annotations

import csv
import io
import os
from collections import defaultdict
from datetime import UTC, date, datetime
from typing import Any

from timesheet import domain
from timesheet.common import client, log, metric, table


def query_all(tbl: Any, **kwargs: Any) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    while True:
        page = tbl.query(**kwargs)
        items.extend(page.get("Items", []))
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def collect_handler(event: dict[str, Any], context: Any = None, tbl: Any = None, today: date | None = None):
    """Find every APPROVED timesheet in the period, grouped by employee."""
    tbl = tbl if tbl is not None else table()
    period = event.get("periodStart") or domain.previous_monday(today or datetime.now(UTC).date())
    weeks = domain.period_weeks(period, int(event.get("weeks", 1)))

    items = query_all(
        tbl,
        IndexName="GSI2",
        KeyConditionExpression="GSI2PK = :s AND GSI2SK BETWEEN :first AND :last",
        ExpressionAttributeValues={
            ":s": f"STATUS#{domain.APPROVED}",
            ":first": f"WEEK#{weeks[0]}",
            ":last": f"WEEK#{weeks[-1]}#~",  # "~" sorts after every employee ID
        },
    )
    by_employee: dict[str, list[str]] = defaultdict(list)
    timesheets = []
    for i in items:
        by_employee[i["employeeId"]].append(i["weekStart"])
        timesheets.append({"employeeId": i["employeeId"], "weekStart": i["weekStart"]})

    log(20, "payroll collected", periodStart=period, timesheets=len(timesheets), employees=len(by_employee))
    return {
        "periodStart": period,
        "weeks": len(weeks),
        "count": len(timesheets),
        "employees": [{"employeeId": e, "weekStarts": sorted(w)} for e, w in sorted(by_employee.items())],
        "timesheets": timesheets,
    }


def calculate_handler(event: dict[str, Any], context: Any = None, tbl: Any = None):
    """One employee: load rate + approved weeks, compute gross pay, store the line under the run."""
    tbl = tbl if tbl is not None else table()
    emp, run_id = event["employeeId"], event["runId"]
    profile = tbl.get_item(Key={"PK": domain.employee_pk(emp), "SK": domain.PROFILE_SK}, ConsistentRead=True).get(
        "Item"
    )
    if not profile:
        raise ValueError(f"no profile for employee {emp}")

    weeks: list[tuple[str, int]] = []
    for week in event["weekStarts"]:
        ts = tbl.get_item(
            Key={"PK": domain.employee_pk(emp), "SK": domain.week_sk(week)}, ConsistentRead=True
        ).get("Item")
        if not ts or ts["status"] not in (domain.APPROVED, domain.PAID):
            raise ValueError(f"timesheet {emp}/{week} is no longer approved")
        weeks.append((week, int(ts["totalQuarterHours"])))

    line = domain.payroll_line(emp, profile["name"], int(profile["hourlyRateCents"]), weeks)
    tbl.put_item(
        Item={
            "PK": f"PAYRUN#{run_id}",
            "SK": f"LINE#{emp}",
            **{k: v for k, v in line.items() if k not in ("regularHours", "overtimeHours")},
            # Stored as integer quarter-hours: DynamoDB numbers must not be floats.
            "regularQuarterHours": int(line["regularHours"] * 4),
            "overtimeQuarterHours": int(line["overtimeHours"] * 4),
        }
    )
    return {"employeeId": emp, "calculated": True}  # no pay data in execution history


CSV_FIELDS = ["employee_id", "name", "weeks", "regular_hours", "overtime_hours", "hourly_rate", "gross_pay"]


def render_csv(lines: list[dict[str, Any]]) -> str:
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n")
    writer.writerow(CSV_FIELDS)
    for line in sorted(lines, key=lambda x: str(x["employeeId"])):
        writer.writerow(
            [
                line["employeeId"],
                # Defuse spreadsheet formula injection in a user-supplied field.
                ("'" + line["name"]) if str(line["name"])[:1] in "=+-@" else line["name"],
                " ".join(line["weeks"]),
                int(line["regularQuarterHours"]) / 4,
                int(line["overtimeQuarterHours"]) / 4,
                domain.cents_to_dollars(int(line["hourlyRateCents"])),
                domain.cents_to_dollars(int(line["grossCents"])),
            ]
        )
    return buf.getvalue()


def export_handler(event: dict[str, Any], context: Any = None, tbl: Any = None, s3: Any = None):
    """Write the run's lines to an encrypted CSV in S3; return totals only."""
    tbl = tbl if tbl is not None else table()
    s3 = s3 if s3 is not None else client("s3")
    run_id, period = event["runId"], event["periodStart"]
    lines = query_all(
        tbl,
        KeyConditionExpression="PK = :pk AND begins_with(SK, :line)",
        ExpressionAttributeValues={":pk": f"PAYRUN#{run_id}", ":line": "LINE#"},
    )
    key = f"payroll/{period}/{run_id}.csv"
    s3.put_object(
        Bucket=os.environ["EXPORTS_BUCKET"],
        Key=key,
        Body=render_csv(lines).encode("utf-8"),
        ContentType="text/csv",
        ServerSideEncryption="aws:kms",
        SSEKMSKeyId=os.environ["KMS_KEY_ARN"],
    )
    gross = sum(int(x["grossCents"]) for x in lines)
    metric("PayrollGrossCents", gross, "None")
    metric("PayrollEmployeesPaid", len(lines))
    log(20, "payroll exported", runId=run_id, employees=len(lines), key=key)
    return {
        "exportKey": key,
        "employeeCount": len(lines),
        "grossCents": gross,
        "overtimeQuarterHours": sum(int(x["overtimeQuarterHours"]) for x in lines),
    }
