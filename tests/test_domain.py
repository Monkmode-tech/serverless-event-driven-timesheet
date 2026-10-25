import unittest
from datetime import date

import fakes  # noqa: F401 - puts src/ on sys.path

from timesheet import domain

TODAY = date(2026, 10, 21)  # a Wednesday
MONDAY = "2026-10-19"


def submission(**overrides):
    body = {
        "weekStart": MONDAY,
        "entries": [
            {"date": "2026-10-19", "projectCode": "ACME-12", "hours": 8},
            {"date": "2026-10-20", "projectCode": "ACME-12", "hours": 7.5},
            {"date": "2026-10-20", "projectCode": "OPS-7", "hours": 0.5},
        ],
    }
    body.update(overrides)
    return body


class ValidationTests(unittest.TestCase):
    def test_valid_submission_converts_hours_to_quarter_hours(self):
        week, entries, note = domain.validate_submission(submission(), TODAY)
        self.assertEqual(week, MONDAY)
        self.assertEqual([e.quarter_hours for e in entries], [32, 30, 2])
        self.assertEqual(note, "")

    def test_week_must_start_on_a_monday(self):
        with self.assertRaisesRegex(domain.ValidationError, "Monday"):
            domain.validate_submission(submission(weekStart="2026-10-20"), TODAY)

    def test_future_weeks_are_rejected(self):
        with self.assertRaisesRegex(domain.ValidationError, "future"):
            domain.validate_submission(submission(weekStart="2026-10-26"), TODAY)

    def test_very_old_weeks_need_hr(self):
        with self.assertRaisesRegex(domain.ValidationError, "26 weeks"):
            domain.validate_submission(submission(weekStart="2026-01-05"), TODAY)

    def test_entry_dates_must_be_inside_the_week(self):
        body = submission(entries=[{"date": "2026-10-26", "projectCode": "ACME-1", "hours": 1}])
        with self.assertRaisesRegex(domain.ValidationError, "fall in the week"):
            domain.validate_submission(body, TODAY)

    def test_quarter_hour_increments_only(self):
        body = submission(entries=[{"date": MONDAY, "projectCode": "ACME-1", "hours": 1.1}])
        with self.assertRaisesRegex(domain.ValidationError, "quarter-hour"):
            domain.validate_submission(body, TODAY)

    def test_hours_must_be_numbers_not_booleans_or_strings(self):
        for bad in (True, "8", None):
            body = submission(entries=[{"date": MONDAY, "projectCode": "ACME-1", "hours": bad}])
            with self.assertRaises(domain.ValidationError):
                domain.validate_submission(body, TODAY)

    def test_project_code_format(self):
        body = submission(entries=[{"date": MONDAY, "projectCode": "acme 12; DROP", "hours": 1}])
        with self.assertRaisesRegex(domain.ValidationError, "projectCode"):
            domain.validate_submission(body, TODAY)

    def test_no_more_than_24_hours_in_a_day_across_entries(self):
        body = submission(entries=[
            {"date": MONDAY, "projectCode": "ACME-1", "hours": 16},
            {"date": MONDAY, "projectCode": "OPS-1", "hours": 8.25},
        ])
        with self.assertRaisesRegex(domain.ValidationError, "24 hours"):
            domain.validate_submission(body, TODAY)

    def test_weekly_cap(self):
        days = ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"]
        body = submission(entries=[{"date": d, "projectCode": "ACME-1", "hours": 12} for d in days])
        with self.assertRaisesRegex(domain.ValidationError, "80 hours"):
            domain.validate_submission(body, TODAY)

    def test_profile_rate_bounds(self):
        good = {"name": "Ada", "department": "engineering",
                "managerId": "11111111-1111-1111-1111-111111111111", "hourlyRateCents": 4500}
        self.assertEqual(domain.validate_profile(good)["hourlyRateCents"], 4500)
        for rate in (700, 100_001, 45.5, True):
            with self.assertRaises(domain.ValidationError):
                domain.validate_profile({**good, "hourlyRateCents": rate})


class LifecycleTests(unittest.TestCase):
    def test_allowed_transitions(self):
        for current, target in [(None, "SUBMITTED"), ("SUBMITTED", "APPROVED"), ("SUBMITTED", "REJECTED"),
                                ("REJECTED", "SUBMITTED"), ("APPROVED", "PAID")]:
            domain.check_transition(current, target)

    def test_forbidden_transitions(self):
        for current, target in [("APPROVED", "SUBMITTED"), ("PAID", "SUBMITTED"), ("SUBMITTED", "PAID"),
                                (None, "APPROVED"), ("REJECTED", "APPROVED")]:
            with self.assertRaises(domain.TransitionError):
                domain.check_transition(current, target)


class PayTests(unittest.TestCase):
    def test_no_overtime_at_or_below_40_hours(self):
        pay = domain.week_pay(MONDAY, 40 * 4, 2000)
        self.assertEqual((pay.regular_qh, pay.overtime_qh, pay.gross_cents), (160, 0, 80_000))

    def test_overtime_is_time_and_a_half_over_40_hours(self):
        pay = domain.week_pay(MONDAY, 45 * 4, 2000)  # 40 x $20 + 5 x $30
        self.assertEqual((pay.overtime_qh, pay.gross_cents), (20, 95_000))

    def test_rounding_is_half_up_to_the_cent(self):
        self.assertEqual(domain.week_pay(MONDAY, 1, 1001).gross_cents, 250)  # 250.25 -> 250
        self.assertEqual(domain.week_pay(MONDAY, 1, 1002).gross_cents, 251)  # 250.50 -> 251
        # 40h + 0.25h OT at $10.01: 40040 + 375.375 -> 40415
        self.assertEqual(domain.week_pay(MONDAY, 161, 1001).gross_cents, 40_415)

    def test_overtime_is_per_week_not_per_period(self):
        line = domain.payroll_line("e1", "Ada", 2000, [("2026-10-12", 30 * 4), ("2026-10-19", 50 * 4)])
        # 30h + (40h + 10h OT): 600 + 800 + 300 = $1,700 (pooling would give 80h, no OT)
        self.assertEqual(line["grossCents"], 170_000)
        self.assertEqual(line["overtimeHours"], 10)

    def test_period_helpers(self):
        self.assertEqual(domain.period_weeks("2026-10-12", 2), ["2026-10-12", "2026-10-19"])
        self.assertEqual(domain.previous_monday(TODAY), "2026-10-12")
        self.assertEqual(domain.previous_monday(date(2026, 10, 19)), "2026-10-12")
        self.assertEqual(domain.cents_to_dollars(95_005), "950.05")
        with self.assertRaises(domain.ValidationError):
            domain.period_weeks("2026-10-13", 1)


if __name__ == "__main__":
    unittest.main()
