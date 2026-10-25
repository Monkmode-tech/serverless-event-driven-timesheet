import csv
import io
import os
import unittest
from datetime import date
from unittest import mock

from fakes import FakeS3, FakeTable

from timesheet import payroll

E1 = "aaaaaaaa-0000-0000-0000-000000000001"
E2 = "eeeeeeee-0000-0000-0000-000000000005"


def timesheet(emp, week, qh, status="APPROVED"):
    return {"PK": f"EMP#{emp}", "SK": f"WEEK#{week}", "employeeId": emp, "weekStart": week, "status": status,
            "totalQuarterHours": qh, "GSI2PK": f"STATUS#{status}", "GSI2SK": f"WEEK#{week}#EMP#{emp}"}


def profile(emp, name, rate):
    return {"PK": f"EMP#{emp}", "SK": "PROFILE", "name": name, "hourlyRateCents": rate}


class PayrollTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"EXPORTS_BUCKET": "exports", "KMS_KEY_ARN": "arn:aws:kms:k"})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.tbl = FakeTable([
            profile(E1, "Ada Lovelace", 4000),
            profile(E2, "=HYPERLINK(\"http://evil\")", 2000),
            timesheet(E1, "2026-10-12", 45 * 4),
            timesheet(E1, "2026-10-19", 40 * 4),
            timesheet(E2, "2026-10-12", 20 * 4),
            timesheet(E2, "2026-10-05", 40 * 4),               # outside the period
            timesheet(E2, "2026-10-19", 8 * 4, "SUBMITTED"),   # not approved
        ])

    def test_collect_finds_only_approved_weeks_in_the_period(self):
        out = payroll.collect_handler({"periodStart": "2026-10-12", "weeks": 2}, tbl=self.tbl)
        self.assertEqual(out["count"], 3)
        self.assertEqual(out["employees"], [{"employeeId": E1, "weekStarts": ["2026-10-12", "2026-10-19"]},
                                            {"employeeId": E2, "weekStarts": ["2026-10-12"]}])

    def test_scheduled_run_defaults_to_last_completed_week(self):
        out = payroll.collect_handler({}, tbl=self.tbl, today=date(2026, 10, 21))
        self.assertEqual((out["periodStart"], out["count"]), ("2026-10-12", 2))

    def test_calculate_keeps_pay_out_of_the_workflow_state(self):
        out = payroll.calculate_handler({"employeeId": E1, "weekStarts": ["2026-10-12", "2026-10-19"],
                                         "runId": "r1"}, tbl=self.tbl)
        self.assertEqual(out, {"employeeId": E1, "calculated": True})
        line = self.tbl.items[("PAYRUN#r1", f"LINE#{E1}")]
        # week 1: 40h x $40 + 5h x $60 = 1,900; week 2: 40h x $40 = 1,600
        self.assertEqual(line["grossCents"], 350_000)
        self.assertEqual((line["regularQuarterHours"], line["overtimeQuarterHours"]), (320, 20))
        self.assertFalse(any(isinstance(v, float) for v in line.values()))

    def test_calculate_refuses_a_week_that_is_no_longer_approved(self):
        with self.assertRaisesRegex(ValueError, "no longer approved"):
            payroll.calculate_handler({"employeeId": E2, "weekStarts": ["2026-10-19"], "runId": "r1"}, tbl=self.tbl)

    def test_export_writes_encrypted_csv_and_defuses_formulas(self):
        for emp, weeks in ((E1, ["2026-10-12", "2026-10-19"]), (E2, ["2026-10-12"])):
            payroll.calculate_handler({"employeeId": emp, "weekStarts": weeks, "runId": "r1"}, tbl=self.tbl)
        s3 = FakeS3()
        out = payroll.export_handler({"runId": "r1", "periodStart": "2026-10-12"}, tbl=self.tbl, s3=s3)
        self.assertEqual(out["grossCents"], 350_000 + 40_000)
        self.assertEqual(out["employeeCount"], 2)
        obj = s3.objects["payroll/2026-10-12/r1.csv"]
        self.assertEqual(obj["ServerSideEncryption"], "aws:kms")
        rows = list(csv.DictReader(io.StringIO(obj["Body"].decode())))
        self.assertEqual(rows[0]["gross_pay"], "3500.00")
        self.assertTrue(rows[1]["name"].startswith("'="))


if __name__ == "__main__":
    unittest.main()
