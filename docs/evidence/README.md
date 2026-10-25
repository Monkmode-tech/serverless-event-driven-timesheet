# Evidence

Scripts write reports here (`e2e-*.md`). Add screenshots with these names, then copy the headline
numbers into the Results table in the top-level README. Redact emails and account IDs first.

| # | File | What it proves |
|---|---|---|
| 1 | `01-terraform-apply.png` | Whole system deployed from code |
| 2 | `02-e2e-report.png` | `make e2e`: submit → approve → ledger → payroll → CSV, all PASS |
| 3 | `03-authz-403.png` | Employee calling an HR route gets 403; no token gets 401 |
| 4 | `04-step-functions-graph.png` | Successful payroll execution (graph view, green) |
| 5 | `05-payroll-csv.png` | Export with 40 regular + 5 overtime hours = $1,900.00 (demo data) |
| 6 | `06-dashboard.png` | Dashboard: p95 latency, cost per 1k requests, queues, payroll runs |
| 7 | `07-dlq-alarm.png` | `make dlq-drill`: message in the DLQ, alarm in ALARM, email received |
| 8 | `08-replay-pass.png` | `make replay-drill`: totals unchanged after replaying events |
| 9 | `09-xray-trace.png` | X-Ray service map / trace through API → Lambda → DynamoDB |
| 10 | `10-s3-lifecycle.png` | Exports bucket lifecycle rule (Glacier 90 d, expire 7 y) |
| 11 | `11-cost-explorer.png` | A month of actual cost for the project tag |
