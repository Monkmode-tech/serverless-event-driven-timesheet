# Security and privacy

Timesheets and pay rates are confidential employee data (PII + compensation). Every design choice
below has the same goal: each person and component sees only the data its job requires.

## Who can do what

| Action | employees | managers | hr |
|---|---|---|---|
| Submit / resubmit own timesheet | ✓ | ✓ (also in employees) | ✓ (also in employees) |
| See own timesheets | ✓ | ✓ | ✓ |
| Approve / reject | | **own direct reports only**, never self | |
| Project hour reports | | ✓ | ✓ |
| Read or set pay rates and managers | | | ✓ |
| Start payroll, download the export | | | ✓ |

Enforced in three layers:

1. **Edge:** API Gateway JWT authorizer. No valid Cognito access token means a 401 before any code runs.
2. **Route:** `ROUTES` in `src/timesheet/api.py` maps each route to its allowed groups (403 otherwise).
3. **Data:** conditional writes (`managerId = :me`, expected `status` and `version`), plus "not found"
   for timesheets outside a manager's team, so team membership can't be probed.

## Where sensitive data does and doesn't go

| Data | Stored | Never appears in |
|---|---|---|
| Pay rates | DynamoDB `PROFILE` items (HR-only API) | events, logs, notifications, workflow state, employee/manager API responses |
| Names | DynamoDB profile, payroll CSV | events, logs, notifications, workflow state |
| Hours | DynamoDB timesheets | logs, notifications |
| Payroll totals | Run record, `PayrollCompleted` event (head count only) | logs |

How each "never" is enforced:

- **Pipe filter** passes only `WEEK#` items, so profile changes never become events, and its input
  template copies only IDs, status and version.
- **Logging helper** (`common.log`) is used only with IDs. Tests assert notifications carry no names or hours.
- **Step Functions** logs at ERROR level with `include_execution_data = false`, and the state passes IDs only.

## Encryption and retention

- One customer-managed KMS key (rotation on) for DynamoDB and its stream, S3, SQS, SNS, CloudWatch
  Logs and Lambda environment variables.
- The exports bucket blocks public access, denies non-TLS requests, and **denies uploads not
  encrypted with the app's key**. HR downloads use presigned links that expire in 5 minutes.
- Payroll CSVs move to Glacier after 90 days and are deleted after 7 years. The FLSA requires 3;
  7 is the assumed company policy (variable `retention_days`).
- DynamoDB point-in-time recovery (35 days) and deletion protection.
- CSV export defuses spreadsheet formula injection (names starting with `= + - @`).

## Identity

- Cognito: admin-created accounts only, 14-character passwords, optional TOTP MFA, case-insensitive
  usernames, `prevent_user_existence_errors`, token revocation. Access tokens last 60 minutes.
- `USER_PASSWORD_AUTH` is enabled **only** for the lab's scripted tests
  (`enable_password_auth_for_tests`). Production clients use SRP or the hosted UI with PKCE.
- Every Lambda, the Pipe, the state machine and the scheduler has its own role, scoped to the
  specific table, index, queue, bucket prefix or state machine it uses.

## Known gaps (and the fix)

| Gap | Production fix |
|---|---|
| No WAF on the HTTP API | CloudFront + AWS WAF in front, or a REST API with WAF |
| Optional MFA | Require MFA for the `hr` group (Cognito pre-authentication check, or move HR to IdP federation with MFA) |
| One KMS key for all data | Separate key for payroll exports with an HR-only key policy |
| Shared notifications topic | Per-recipient SES email; no message content beyond a link |
