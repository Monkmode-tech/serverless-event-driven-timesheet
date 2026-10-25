"""Timesheet domain rules - pure functions, no AWS calls, fully unit-tested.

Hours are stored as integer *quarter-hours* and money as integer *cents*, so
there is no floating-point rounding anywhere in payroll.

Lifecycle of a weekly timesheet:

    (none) --submit--> SUBMITTED --approve--> APPROVED --payroll--> PAID
                            |
                            +--reject--> REJECTED --submit--> SUBMITTED
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, timedelta

SUBMITTED = "SUBMITTED"
APPROVED = "APPROVED"
REJECTED = "REJECTED"
PAID = "PAID"
STATUSES = (SUBMITTED, APPROVED, REJECTED, PAID)

PROJECT_CODE = re.compile(r"^[A-Z]{2,5}-\d{1,4}$")
MAX_DAY_QH = 24 * 4
MAX_WEEK_QH = 80 * 4
OVERTIME_THRESHOLD_QH = 40 * 4  # FLSA: overtime after 40 hours in a workweek
MAX_ENTRIES = 50
MAX_NOTE = 500


class ValidationError(ValueError):
    """Client input that breaks a business rule (maps to HTTP 400)."""


class TransitionError(ValueError):
    """A status change that the lifecycle does not allow (maps to HTTP 409)."""


# ---------------------------------------------------------------------------
# Keys (single-table design)
# ---------------------------------------------------------------------------
def employee_pk(employee_id: str) -> str:
    return f"EMP#{employee_id}"


def week_sk(week_start: str) -> str:
    return f"WEEK#{week_start}"


PROFILE_SK = "PROFILE"


def manager_gsi(manager_id: str, status: str, week_start: str, employee_id: str) -> dict[str, str]:
    """GSI1 - a manager's queue: all their reports' timesheets, by status then week."""
    return {"GSI1PK": f"MGR#{manager_id}", "GSI1SK": f"STATUS#{status}#WEEK#{week_start}#EMP#{employee_id}"}


def status_gsi(status: str, week_start: str, employee_id: str) -> dict[str, str]:
    """GSI2 - every timesheet in a status, by week (payroll reads APPROVED weeks)."""
    return {"GSI2PK": f"STATUS#{status}", "GSI2SK": f"WEEK#{week_start}#EMP#{employee_id}"}


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
def monday(value: object, field: str = "weekStart") -> date:
    """Format check only: an ISO date that is a Monday."""
    if not isinstance(value, str) or not re.match(r"^\d{4}-\d{2}-\d{2}$", value):
        raise ValidationError(f"{field} must be an ISO date (YYYY-MM-DD)")
    try:
        day = date.fromisoformat(value)
    except ValueError as exc:
        raise ValidationError(f"{field} must be an ISO date (YYYY-MM-DD)") from exc
    if day.weekday() != 0:
        raise ValidationError(f"{field} must be a Monday")
    return day


def parse_monday(value: object, today: date | None = None) -> date:
    """A Monday that an employee may submit for: not in the future, not older than 26 weeks."""
    day = monday(value)
    today = today or date.today()
    if day > today:
        raise ValidationError("weekStart cannot be in the future")
    if day < today - timedelta(days=7 * 26):
        raise ValidationError("weekStart is more than 26 weeks ago; contact HR for corrections")
    return day


def hours_to_qh(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise ValidationError("hours must be a number")
    qh = value * 4
    if qh != int(qh):
        raise ValidationError("hours must be in quarter-hour increments (e.g. 7.25)")
    qh = int(qh)
    if qh <= 0 or qh > MAX_DAY_QH:
        raise ValidationError("hours must be greater than 0 and at most 24")
    return qh


@dataclass(frozen=True)
class Entry:
    day: str
    project_code: str
    quarter_hours: int

    def to_item(self) -> dict[str, object]:
        return {"date": self.day, "projectCode": self.project_code, "quarterHours": self.quarter_hours}


def validate_submission(body: object, today: date | None = None) -> tuple[str, list[Entry], str]:
    """Return (week_start, entries, note) or raise ValidationError."""
    if not isinstance(body, dict):
        raise ValidationError("body must be a JSON object")
    start = parse_monday(body.get("weekStart"), today)
    week = {(start + timedelta(days=i)).isoformat() for i in range(7)}

    raw = body.get("entries")
    if not isinstance(raw, list) or not raw:
        raise ValidationError("entries must be a non-empty list")
    if len(raw) > MAX_ENTRIES:
        raise ValidationError(f"at most {MAX_ENTRIES} entries per week")

    entries: list[Entry] = []
    per_day: dict[str, int] = {}
    for i, e in enumerate(raw):
        if not isinstance(e, dict):
            raise ValidationError(f"entries[{i}] must be an object")
        day = e.get("date")
        if day not in week:
            raise ValidationError(f"entries[{i}].date must fall in the week starting {start.isoformat()}")
        code = e.get("projectCode")
        if not isinstance(code, str) or not PROJECT_CODE.match(code):
            raise ValidationError(f"entries[{i}].projectCode must look like ABC-123")
        qh = hours_to_qh(e.get("hours"))
        per_day[day] = per_day.get(day, 0) + qh
        if per_day[day] > MAX_DAY_QH:
            raise ValidationError(f"more than 24 hours recorded on {day}")
        entries.append(Entry(day, code, qh))

    total = sum(e.quarter_hours for e in entries)
    if total > MAX_WEEK_QH:
        raise ValidationError("more than 80 hours in one week needs HR approval")

    note = body.get("note", "")
    if not isinstance(note, str) or len(note) > MAX_NOTE:
        raise ValidationError(f"note must be a string of at most {MAX_NOTE} characters")
    return start.isoformat(), entries, note


def validate_profile(body: object) -> dict[str, object]:
    """HR-maintained employee profile (the only place pay rates live)."""
    if not isinstance(body, dict):
        raise ValidationError("body must be a JSON object")
    name = body.get("name")
    if not isinstance(name, str) or not 1 <= len(name) <= 100:
        raise ValidationError("name is required (1-100 characters)")
    department = body.get("department")
    if not isinstance(department, str) or not re.match(r"^[a-z][a-z0-9-]{1,30}$", department):
        raise ValidationError("department must be a lowercase slug, e.g. engineering")
    manager_id = body.get("managerId")
    if not isinstance(manager_id, str) or not re.match(r"^[0-9a-f-]{36}$", manager_id):
        raise ValidationError("managerId must be the manager's user ID (UUID)")
    rate = body.get("hourlyRateCents")
    if isinstance(rate, bool) or not isinstance(rate, int) or not 725 <= rate <= 100_000:
        raise ValidationError("hourlyRateCents must be an integer between 725 (federal minimum) and 100000")
    return {"name": name, "department": department, "managerId": manager_id, "hourlyRateCents": rate}


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
ALLOWED = {
    None: {SUBMITTED},
    SUBMITTED: {APPROVED, REJECTED},
    REJECTED: {SUBMITTED},
    APPROVED: {PAID},
    PAID: set(),
}


def check_transition(current: str | None, target: str) -> None:
    if target not in ALLOWED.get(current, set()):
        raise TransitionError(f"cannot move a timesheet from {current or 'nothing'} to {target}")


# ---------------------------------------------------------------------------
# Pay
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class WeekPay:
    week_start: str
    regular_qh: int
    overtime_qh: int
    gross_cents: int


def week_pay(week_start: str, total_qh: int, rate_cents: int) -> WeekPay:
    """FLSA weekly overtime: hours over 40 in the workweek are paid at 1.5x.

    gross = regular_qh/4 * rate + overtime_qh/4 * rate * 1.5
          = (2*regular_qh*rate + 3*overtime_qh*rate) / 8, rounded half up to the cent.
    """
    if total_qh < 0 or rate_cents < 0:
        raise ValueError("hours and rate must be non-negative")
    regular = min(total_qh, OVERTIME_THRESHOLD_QH)
    overtime = total_qh - regular
    numerator = 2 * regular * rate_cents + 3 * overtime * rate_cents
    return WeekPay(week_start, regular, overtime, (numerator + 4) // 8)


def total_quarter_hours(entries: list[dict[str, object]]) -> int:
    return sum(int(e["quarterHours"]) for e in entries)


def payroll_line(employee_id: str, name: str, rate_cents: int, weeks: list[tuple[str, int]]) -> dict[str, object]:
    pays = [week_pay(w, qh, rate_cents) for w, qh in sorted(weeks)]
    return {
        "employeeId": employee_id,
        "name": name,
        "hourlyRateCents": rate_cents,
        "weeks": [p.week_start for p in pays],
        "regularHours": sum(p.regular_qh for p in pays) / 4,
        "overtimeHours": sum(p.overtime_qh for p in pays) / 4,
        "grossCents": sum(p.gross_cents for p in pays),
    }


def period_weeks(period_start: object, weeks: int) -> list[str]:
    start = monday(period_start, "periodStart")
    if not 1 <= weeks <= 4:
        raise ValidationError("a payroll period is 1-4 weeks")
    return [(start + timedelta(days=7 * i)).isoformat() for i in range(weeks)]


def previous_monday(today: date) -> str:
    """Monday of the most recent *completed* week (used by the scheduled run)."""
    this_monday = today - timedelta(days=today.weekday())
    return (this_monday - timedelta(days=7)).isoformat()


def cents_to_dollars(cents: int) -> str:
    return f"{cents // 100}.{cents % 100:02d}"
