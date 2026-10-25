"""HTTP API handler (API Gateway HTTP API, payload v2, Cognito JWT authorizer).

Authentication happens at API Gateway (valid Cognito access token or 401).
Authorization happens here, per route, from the caller's Cognito groups AND
the data: a manager may only decide on timesheets of their own reports.

Routes
    GET  /me/timesheets                                    employees
    PUT  /me/timesheets/{weekStart}                        employees  submit / resubmit
    GET  /manager/queue                                    managers   my reports' SUBMITTED weeks
    POST /manager/timesheets/{employeeId}/{weekStart}/decision  managers  approve / reject
    GET  /reports/projects/{projectCode}                   managers, hr
    GET  /hr/employees/{employeeId}                        hr
    PUT  /hr/employees/{employeeId}                        hr  (the only place pay rates are set)
    POST /hr/payroll-runs                                  hr  start the payroll workflow
    GET  /hr/payroll-runs/{periodStart}                    hr  status + short-lived download link
"""

from __future__ import annotations

import json
import os
import re
from datetime import UTC, date, datetime
from typing import Any

from timesheet import domain
from timesheet.common import EMPLOYEES, HR, MANAGERS, Caller, client, error, log, metric, response, table

UUID = re.compile(r"^[0-9a-f-]{36}$")


def now_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def error_code(exc: Exception) -> str:
    return getattr(exc, "response", {}).get("Error", {}).get("Code", "")


def body_of(event: dict[str, Any]) -> Any:
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        import base64

        raw = base64.b64decode(raw).decode("utf-8")
    try:
        return json.loads(raw) if raw else None
    except ValueError:
        return None


def public_timesheet(item: dict[str, Any]) -> dict[str, Any]:
    """Strip key attributes before returning an item to a client."""
    return {k: v for k, v in item.items() if not k.startswith(("PK", "SK", "GSI"))}


# ---------------------------------------------------------------------------
# Employees
# ---------------------------------------------------------------------------
def my_timesheets(caller: Caller, tbl: Any) -> dict[str, Any]:
    result = tbl.query(
        KeyConditionExpression="PK = :pk AND begins_with(SK, :week)",
        ExpressionAttributeValues={":pk": domain.employee_pk(caller.user_id), ":week": "WEEK#"},
        ScanIndexForward=False,
        Limit=26,
    )
    return response(200, {"timesheets": [public_timesheet(i) for i in result.get("Items", [])]})


def submit(caller: Caller, week_param: str, event: dict[str, Any], tbl: Any, today: date | None = None):
    body = body_of(event) or {}
    if body.get("weekStart", week_param) != week_param:
        return error(400, "weekStart in the body must match the URL")
    body["weekStart"] = week_param
    week, entries, note = domain.validate_submission(body, today)

    profile = tbl.get_item(Key={"PK": domain.employee_pk(caller.user_id), "SK": domain.PROFILE_SK}).get("Item")
    if not profile:
        return error(409, "your employee profile has not been set up by HR yet")

    key = {"PK": domain.employee_pk(caller.user_id), "SK": domain.week_sk(week)}
    current = tbl.get_item(Key=key).get("Item")
    domain.check_transition(current["status"] if current else None, domain.SUBMITTED)
    version = int(current["version"]) + 1 if current else 1

    item = {
        **key,
        **domain.manager_gsi(profile["managerId"], domain.SUBMITTED, week, caller.user_id),
        **domain.status_gsi(domain.SUBMITTED, week, caller.user_id),
        "employeeId": caller.user_id,
        "weekStart": week,
        "status": domain.SUBMITTED,
        "entries": [e.to_item() for e in entries],
        "totalQuarterHours": sum(e.quarter_hours for e in entries),
        "note": note,
        "managerId": profile["managerId"],
        "submittedAt": now_iso(),
        "version": version,
    }
    # Optimistic concurrency: new week, or exactly the REJECTED version we read.
    tbl.put_item(
        Item=item,
        ConditionExpression="attribute_not_exists(PK) OR (#s = :rejected AND #v = :v)",
        ExpressionAttributeNames={"#s": "status", "#v": "version"},
        ExpressionAttributeValues={":rejected": domain.REJECTED, ":v": version - 1},
    )
    metric("TimesheetSubmitted", 1)
    log(20, "timesheet submitted", employeeId=caller.user_id, week=week, version=version)
    return response(201 if version == 1 else 200, public_timesheet(item))


# ---------------------------------------------------------------------------
# Managers
# ---------------------------------------------------------------------------
def manager_queue(caller: Caller, tbl: Any) -> dict[str, Any]:
    result = tbl.query(
        IndexName="GSI1",
        KeyConditionExpression="GSI1PK = :mgr AND begins_with(GSI1SK, :status)",
        ExpressionAttributeValues={":mgr": f"MGR#{caller.user_id}", ":status": f"STATUS#{domain.SUBMITTED}#"},
        Limit=100,
    )
    return response(200, {"pending": [public_timesheet(i) for i in result.get("Items", [])]})


def decide(caller: Caller, employee_id: str, week: str, event: dict[str, Any], tbl: Any) -> dict[str, Any]:
    if not UUID.match(employee_id):
        return error(400, "invalid employeeId")
    domain.monday(week)
    body = body_of(event) or {}
    decision = body.get("decision")
    if decision not in ("approve", "reject"):
        return error(400, "decision must be 'approve' or 'reject'")
    reason = body.get("reason", "")
    if decision == "reject" and (not isinstance(reason, str) or not 1 <= len(reason) <= 500):
        return error(400, "a rejection needs a reason (1-500 characters)")
    if employee_id == caller.user_id:
        return error(403, "you cannot approve your own timesheet")

    key = {"PK": domain.employee_pk(employee_id), "SK": domain.week_sk(week)}
    current = tbl.get_item(Key=key).get("Item")
    # Same answer for "missing" and "not your report", so managers can't probe other teams.
    if not current or current.get("managerId") != caller.user_id:
        return error(404, "timesheet not found")
    target = domain.APPROVED if decision == "approve" else domain.REJECTED
    domain.check_transition(current["status"], target)

    decided_at = now_iso()
    gsi = {
        **domain.manager_gsi(caller.user_id, target, week, employee_id),
        **domain.status_gsi(target, week, employee_id),
    }
    tbl.update_item(
        Key=key,
        UpdateExpression=(
            "SET #s = :t, GSI1SK = :g1, GSI2PK = :g2pk, GSI2SK = :g2sk, "
            "decidedAt = :at, decidedBy = :me, reason = :r, #v = :next"
        ),
        ConditionExpression="#s = :submitted AND #v = :v AND managerId = :me",
        ExpressionAttributeNames={"#s": "status", "#v": "version"},
        ExpressionAttributeValues={
            ":t": target,
            ":g1": gsi["GSI1SK"],
            ":g2pk": gsi["GSI2PK"],
            ":g2sk": gsi["GSI2SK"],
            ":at": decided_at,
            ":me": caller.user_id,
            ":r": reason if decision == "reject" else "",
            ":submitted": domain.SUBMITTED,
            ":v": int(current["version"]),
            ":next": int(current["version"]) + 1,
        },
    )
    submitted = datetime.fromisoformat(current["submittedAt"])
    metric("ApprovalLatencySeconds", (datetime.fromisoformat(decided_at) - submitted).total_seconds(), "Seconds")
    metric("TimesheetApproved" if target == domain.APPROVED else "TimesheetRejected", 1)
    log(20, "timesheet decided", employeeId=employee_id, week=week, status=target, managerId=caller.user_id)
    return response(200, {"employeeId": employee_id, "weekStart": week, "status": target, "decidedAt": decided_at})


def project_report(project_code: str, tbl: Any) -> dict[str, Any]:
    if not domain.PROJECT_CODE.match(project_code):
        return error(400, "invalid project code")
    result = tbl.query(
        KeyConditionExpression="PK = :pk",
        ExpressionAttributeValues={":pk": f"PROJECT#{project_code}"},
        ScanIndexForward=False,
        Limit=52,
    )
    weeks = [
        {"weekStart": i["SK"].removeprefix("WEEK#"), "approvedHours": int(i.get("quarterHours", 0)) / 4}
        for i in result.get("Items", [])
    ]
    return response(200, {"projectCode": project_code, "weeks": weeks})


# ---------------------------------------------------------------------------
# HR
# ---------------------------------------------------------------------------
def get_profile(employee_id: str, tbl: Any) -> dict[str, Any]:
    if not UUID.match(employee_id):
        return error(400, "invalid employeeId")
    item = tbl.get_item(Key={"PK": domain.employee_pk(employee_id), "SK": domain.PROFILE_SK}).get("Item")
    return response(200, public_timesheet(item)) if item else error(404, "employee not found")


def put_profile(caller: Caller, employee_id: str, event: dict[str, Any], tbl: Any) -> dict[str, Any]:
    if not UUID.match(employee_id):
        return error(400, "invalid employeeId")
    profile = domain.validate_profile(body_of(event))
    if profile["managerId"] == employee_id:
        return error(400, "an employee cannot be their own manager")
    item = {
        "PK": domain.employee_pk(employee_id),
        "SK": domain.PROFILE_SK,
        "employeeId": employee_id,
        **profile,
        "updatedAt": now_iso(),
        "updatedBy": caller.user_id,
    }
    tbl.put_item(Item=item)
    log(20, "profile updated", employeeId=employee_id, by=caller.user_id)  # no name or rate in logs
    return response(200, public_timesheet(item))


def start_payroll(event: dict[str, Any], sfn: Any, today: date | None = None) -> dict[str, Any]:
    body = body_of(event) or {}
    period = body.get("periodStart") or domain.previous_monday(today or date.today())
    weeks = body.get("weeks", 1)
    if isinstance(weeks, bool) or not isinstance(weeks, int):
        return error(400, "weeks must be an integer")
    domain.period_weeks(period, weeks)  # validates
    name = f"payroll-{period}-{weeks}w"  # execution names are unique: a period can't run twice by accident
    try:
        result = sfn.start_execution(
            stateMachineArn=os.environ["PAYROLL_STATE_MACHINE_ARN"],
            name=name,
            input=json.dumps({"periodStart": period, "weeks": weeks, "trigger": "api"}),
        )
    except Exception as exc:
        if error_code(exc) == "ExecutionAlreadyExists":
            return error(409, f"payroll for {period} ({weeks} week(s)) has already been started")
        raise
    log(20, "payroll started", periodStart=period, weeks=weeks)
    return response(202, {"periodStart": period, "weeks": weeks, "executionArn": result["executionArn"]})


def payroll_status(period: str, tbl: Any, s3: Any) -> dict[str, Any]:
    domain.monday(period, "periodStart")
    run = tbl.get_item(Key={"PK": f"PAYROLL#{period}", "SK": "RUN"}).get("Item")
    if not run:
        return error(404, "no payroll run for that period")
    out = public_timesheet(run)
    if run.get("status") == "COMPLETED" and run.get("exportKey"):
        out["downloadUrl"] = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": os.environ["EXPORTS_BUCKET"], "Key": run["exportKey"]},
            ExpiresIn=300,
        )
        out["downloadUrlExpiresInSeconds"] = 300
    return response(200, out)


# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------
ROUTES: dict[str, set[str]] = {
    "GET /me/timesheets": {EMPLOYEES},
    "PUT /me/timesheets/{weekStart}": {EMPLOYEES},
    "GET /manager/queue": {MANAGERS},
    "POST /manager/timesheets/{employeeId}/{weekStart}/decision": {MANAGERS},
    "GET /reports/projects/{projectCode}": {MANAGERS, HR},
    "GET /hr/employees/{employeeId}": {HR},
    "PUT /hr/employees/{employeeId}": {HR},
    "POST /hr/payroll-runs": {HR},
    "GET /hr/payroll-runs/{periodStart}": {HR},
}


def handler(event: dict[str, Any], context: Any = None, tbl: Any = None, sfn: Any = None, s3: Any = None):
    route = event.get("routeKey", "")
    allowed = ROUTES.get(route)
    if allowed is None:
        return error(404, "not found")
    caller = Caller.from_event(event)
    if not caller.user_id:
        return error(401, "unauthenticated")
    if not caller.groups & allowed:
        log(30, "forbidden", route=route, userId=caller.user_id)
        return error(403, "forbidden")

    tbl = tbl if tbl is not None else table()
    p = event.get("pathParameters") or {}
    try:
        match route:
            case "GET /me/timesheets":
                return my_timesheets(caller, tbl)
            case "PUT /me/timesheets/{weekStart}":
                return submit(caller, p.get("weekStart", ""), event, tbl)
            case "GET /manager/queue":
                return manager_queue(caller, tbl)
            case "POST /manager/timesheets/{employeeId}/{weekStart}/decision":
                return decide(caller, p.get("employeeId", ""), p.get("weekStart", ""), event, tbl)
            case "GET /reports/projects/{projectCode}":
                return project_report(p.get("projectCode", ""), tbl)
            case "GET /hr/employees/{employeeId}":
                return get_profile(p.get("employeeId", ""), tbl)
            case "PUT /hr/employees/{employeeId}":
                return put_profile(caller, p.get("employeeId", ""), event, tbl)
            case "POST /hr/payroll-runs":
                return start_payroll(event, sfn if sfn is not None else client("stepfunctions"))
            case _:  # "GET /hr/payroll-runs/{periodStart}"
                return payroll_status(p.get("periodStart", ""), tbl, s3 if s3 is not None else client("s3"))
    except domain.ValidationError as exc:
        return error(400, str(exc))
    except domain.TransitionError as exc:
        return error(409, str(exc))
    except Exception as exc:
        if error_code(exc) == "ConditionalCheckFailedException":
            return error(409, "the timesheet changed while you were working on it; reload and try again")
        log(40, "unhandled error", route=route, error=type(exc).__name__)
        return error(500, "internal error")
