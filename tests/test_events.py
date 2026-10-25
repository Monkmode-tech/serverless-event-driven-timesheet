import json
import os
import unittest
from unittest import mock

from fakes import FakeDynamoDBClient, FakeSNS, FakeTable

from timesheet import events

EMP = "aaaaaaaa-0000-0000-0000-000000000001"
MGR = "bbbbbbbb-0000-0000-0000-000000000002"


def sqs_record(status, version=1, message_id="m1", **extra):
    detail = {"employeeId": EMP, "weekStart": "2026-10-12", "status": status, "version": str(version),
              "managerId": MGR, **extra}
    body = {"detail-type": "TimesheetStatusChanged", "source": "timesheet.store", "detail": detail}
    return {"messageId": message_id, "body": json.dumps(body)}


class NotifierTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"NOTIFICATIONS_TOPIC_ARN": "arn:aws:sns:us-east-2:1:n"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_submitted_notifies_the_manager_once_even_if_delivered_twice(self):
        tbl, sns = FakeTable(), FakeSNS()
        record = sqs_record("SUBMITTED")
        self.assertEqual(events.notify_handler({"Records": [record]}, tbl=tbl, sns=sns), {"batchItemFailures": []})
        events.notify_handler({"Records": [record]}, tbl=tbl, sns=sns)  # at-least-once redelivery
        self.assertEqual(len(sns.published), 1)
        attrs = sns.published[0]["MessageAttributes"]
        self.assertEqual(attrs["recipient"]["StringValue"], MGR)

    def test_new_version_is_a_new_notification(self):
        tbl, sns = FakeTable(), FakeSNS()
        events.notify_handler({"Records": [sqs_record("SUBMITTED", 1)]}, tbl=tbl, sns=sns)
        events.notify_handler({"Records": [sqs_record("SUBMITTED", 3)]}, tbl=tbl, sns=sns)
        self.assertEqual(len(sns.published), 2)

    def test_notifications_contain_no_names_or_hours(self):
        tbl, sns = FakeTable(), FakeSNS()
        events.notify_handler({"Records": [sqs_record("APPROVED", 2, name="Ada", totalQuarterHours="160")]},
                              tbl=tbl, sns=sns)
        self.assertNotIn("Ada", sns.published[0]["Message"])
        self.assertNotIn("160", sns.published[0]["Message"])

    def test_poison_message_fails_alone(self):
        tbl, sns = FakeTable(), FakeSNS()
        bad = {"messageId": "bad", "body": "{not json"}
        result = events.notify_handler({"Records": [bad, sqs_record("SUBMITTED", message_id="good")]},
                                       tbl=tbl, sns=sns)
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "bad"}]})
        self.assertEqual(len(sns.published), 1)


class LedgerTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"TABLE_NAME": "timesheet"})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.tbl = FakeTable([{
            "PK": f"EMP#{EMP}", "SK": "WEEK#2026-10-12", "status": "APPROVED", "version": 2,
            "entries": [{"date": "2026-10-12", "projectCode": "ACME-12", "quarterHours": 32},
                        {"date": "2026-10-13", "projectCode": "ACME-12", "quarterHours": 30},
                        {"date": "2026-10-13", "projectCode": "OPS-7", "quarterHours": 2}],
        }])

    def test_approved_hours_are_added_exactly_once(self):
        ddb = FakeDynamoDBClient()
        record = sqs_record("APPROVED", 2)
        for _ in range(3):  # duplicate deliveries
            self.assertEqual(events.ledger_handler({"Records": [record]}, tbl=self.tbl, ddb=ddb),
                             {"batchItemFailures": []})
        self.assertEqual(ddb.totals, {("PROJECT#ACME-12", "WEEK#2026-10-12"): 62,
                                      ("PROJECT#OPS-7", "WEEK#2026-10-12"): 2})

    def test_marker_and_increments_are_one_transaction(self):
        items = events.ledger_transaction("timesheet", {"employeeId": EMP, "weekStart": "2026-10-12", "version": 2},
                                          {"ACME-12": 62})
        self.assertEqual(items[0]["Put"]["ConditionExpression"], "attribute_not_exists(PK)")
        self.assertEqual(items[1]["Update"]["UpdateExpression"], "ADD quarterHours :qh, approvedTimesheets :one")

    def test_other_errors_are_retried_not_swallowed(self):
        ddb = FakeDynamoDBClient()
        with mock.patch.object(ddb, "transact_write_items", side_effect=RuntimeError("throttled")):
            result = events.ledger_handler({"Records": [sqs_record("APPROVED", 2)]}, tbl=self.tbl, ddb=ddb)
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "m1"}]})


if __name__ == "__main__":
    unittest.main()
