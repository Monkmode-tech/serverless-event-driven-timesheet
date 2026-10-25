# ADR 0004: DynamoDB single-table design (not RDS)

- Status: Accepted
- Date: 2026-10

## Context

The access patterns are few and known: my timesheets, my team's pending queue, approved
timesheets in a week, project totals per week, and one employee's profile. The workload is spiky
and small. The CLCS 605 migration plan already targeted DynamoDB.

## Decision

One on-demand table with two GSIs:

| Access pattern | Key |
|---|---|
| My timesheets | `PK = EMP#<me>`, `SK begins_with WEEK#` |
| Manager's pending queue | GSI1 `MGR#<me>` / `STATUS#SUBMITTED#…` |
| Approved in a payroll period | GSI2 `STATUS#APPROVED` / `WEEK#<first> … WEEK#<last>#~` |
| Project hours by week | `PK = PROJECT#<code>` |
| Profile | `EMP#<id>` / `PROFILE` |

## Consequences

- No connection pools, patching or idle instance cost. Streams give the outbox for free (ADR 0002).
- Ad-hoc reporting (for example, "overtime by department last quarter") is not a key-value query.
  The answer is an analytics path: DynamoDB export to S3 + Athena, not SQL against the live table.
- GSI2's partition per status is a write hot-spot only at thousands of approvals per second, far
  beyond this workload. Sharding the key (`STATUS#APPROVED#<n>`) is the known fix.
