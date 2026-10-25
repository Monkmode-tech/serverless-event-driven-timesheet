import json
import os
import unittest
from datetime import date, timedelta
from unittest import mock

from fakes import FakeS3, FakeSFN, FakeTable

from timesheet import api

EMP = "aaaaaaaa-0000-0000-0000-000000000001"
MGR = "bbbbbbbb-0000-0000-0000-000000000002"
OTHER_MGR = "cccccccc-0000-0000-0000-000000000003"
HR_USER = "dddddddd-0000-0000-0000-000000000004"
# Last week's Monday, so submissions are never "in the future" whenever the tests run.
WEEK = (date.today() - timedelta(days=date.today().weekday() + 7)).isoformat()


def event(route, user, groups, path=None, body=None):
    return {
        "routeKey": route,
        "pathParameters": path or {},
        "body": json.dumps(body) if body is not None else None,
        "requestContext": {"authorizer": {"jwt": {"claims": {"sub": user, "cognito:groups": f"[{' '.join(groups)}]"}}}},
    }


def entries(hours=8):
    return {"entries": [{"date": WEEK, "projectCode": "ACME-12", "hours": hours}], "note": "sprint 42"}


class ApiFlowTests(unittest.TestCase):
    def setUp(self):
        self.tbl = FakeTable()
        self.sfn = FakeSFN()
        self.s3 = FakeS3()
        patcher = mock.patch.dict(os.environ, {
            "PAYROLL_STATE_MACHINE_ARN": "arn:aws:states:us-east-2:123456789012:stateMachine:payroll",
            "EXPORTS_BUCKET": "exports"})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.call(event("PUT /hr/employees/{employeeId}", HR_USER, ["hr"], {"employeeId": EMP},
                        {"name": "Ada", "department": "engineering", "managerId": MGR, "hourlyRateCents": 4500}))

    def call(self, ev):
        res = api.handler(ev, tbl=self.tbl, sfn=self.sfn, s3=self.s3)
        return res["statusCode"], json.loads(res["body"])

    def submit(self, user=EMP, hours=8):
        return self.call(event("PUT /me/timesheets/{weekStart}", user, ["employees"], {"weekStart": WEEK},
                               entries(hours)))

    def decide(self, decision, manager=MGR, reason=""):
        return self.call(event("POST /manager/timesheets/{employeeId}/{weekStart}/decision", manager, ["managers"],
                               {"employeeId": EMP, "weekStart": WEEK}, {"decision": decision, "reason": reason}))

    def test_submit_reject_resubmit_approve(self):
        status, body = self.submit()
        self.assertEqual((status, body["status"], body["version"]), (201, "SUBMITTED", 1))
        self.assertNotIn("hourlyRateCents", body)

        status, body = self.call(event("GET /manager/queue", MGR, ["managers"]))
        self.assertEqual((status, len(body["pending"])), (200, 1))

        self.assertEqual(self.decide("reject")[0], 400)  # reason required
        self.assertEqual(self.decide("reject", reason="Wrong project code")[1]["status"], "REJECTED")
        self.assertEqual(self.call(event("GET /manager/queue", MGR, ["managers"]))[1]["pending"], [])

        status, body = self.submit(hours=7.5)
        self.assertEqual((status, body["version"], body["totalQuarterHours"]), (200, 3, 30))  # reject bumped it to 2

        self.assertEqual(self.decide("approve")[1]["status"], "APPROVED")
        item = self.tbl.items[(f"EMP#{EMP}", f"WEEK#{WEEK}")]
        self.assertEqual((item["GSI2PK"], item["version"]), ("STATUS#APPROVED", 4))

    def test_cannot_resubmit_while_pending_or_after_approval(self):
        self.submit()
        self.assertEqual(self.submit()[0], 409)
        self.decide("approve")
        self.assertEqual(self.submit()[0], 409)

    def test_only_the_assigned_manager_can_decide(self):
        self.submit()
        status, body = self.decide("approve", manager=OTHER_MGR)
        self.assertEqual((status, body["error"]), (404, "timesheet not found"))

    def test_lost_update_is_rejected_by_optimistic_concurrency(self):
        self.submit()
        stale = self.tbl.get_item(Key={"PK": f"EMP#{EMP}", "SK": f"WEEK#{WEEK}"})["Item"]
        self.decide("approve")
        # A second decision made from the stale read (version 1) must not overwrite the approval.
        with mock.patch.object(self.tbl, "get_item", return_value={"Item": stale}):
            self.assertEqual(self.decide("reject", reason="late click")[0], 409)
        self.assertEqual(self.tbl.items[(f"EMP#{EMP}", f"WEEK#{WEEK}")]["status"], "APPROVED")

    def test_submit_needs_an_hr_profile(self):
        status, body = self.submit(user=OTHER_MGR)
        self.assertEqual(status, 409)
        self.assertIn("profile", body["error"])

    def test_group_authorization(self):
        self.assertEqual(self.call(event("GET /hr/employees/{employeeId}", EMP, ["employees"],
                                         {"employeeId": EMP}))[0], 403)
        self.assertEqual(self.call(event("GET /manager/queue", EMP, ["employees"]))[0], 403)
        self.assertEqual(self.call(event("GET /me/timesheets", "", []))[0], 401)
        self.assertEqual(self.call(event("DELETE /me/timesheets/{weekStart}", EMP, ["employees"]))[0], 404)

    def test_hr_sees_rates_but_validation_applies(self):
        status, body = self.call(event("GET /hr/employees/{employeeId}", HR_USER, ["hr"], {"employeeId": EMP}))
        self.assertEqual((status, body["hourlyRateCents"]), (200, 4500))
        status, _ = self.call(event("PUT /hr/employees/{employeeId}", HR_USER, ["hr"], {"employeeId": EMP},
                                    {"name": "Ada", "department": "engineering", "managerId": EMP,
                                     "hourlyRateCents": 4500}))
        self.assertEqual(status, 400)  # own manager

    def test_payroll_start_is_idempotent_per_period(self):
        ev = event("POST /hr/payroll-runs", HR_USER, ["hr"], body={"periodStart": "2026-10-12", "weeks": 1})
        self.assertEqual(self.call(ev)[0], 202)
        self.assertEqual(self.call(ev)[0], 409)
        self.assertEqual(self.sfn.calls[0]["name"], "payroll-2026-10-12-1w")

    def test_payroll_status_returns_short_lived_link_when_complete(self):
        self.tbl.put_item(Item={"PK": "PAYROLL#2026-10-12", "SK": "RUN", "status": "COMPLETED",
                                "exportKey": "payroll/2026-10-12/run.csv"})
        status, body = self.call(event("GET /hr/payroll-runs/{periodStart}", HR_USER, ["hr"],
                                       {"periodStart": "2026-10-12"}))
        self.assertEqual((status, body["downloadUrlExpiresInSeconds"]), (200, 300))
        self.assertIn("payroll/2026-10-12/run.csv", body["downloadUrl"])

    def test_invalid_input_is_400_not_500(self):
        status, _ = self.call(event("PUT /me/timesheets/{weekStart}", EMP, ["employees"],
                                    {"weekStart": "not-a-date"}, entries()))
        self.assertEqual(status, 400)
        status, _ = self.call(event("GET /reports/projects/{projectCode}", MGR, ["managers"],
                                    {"projectCode": "../etc"}))
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()
