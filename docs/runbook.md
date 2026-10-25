# Runbook

## Deploy

```bash
aws sso login --profile <p> && export AWS_PROFILE=<p>
cd infra/environments/dev
cp backend.hcl.example backend.hcl            # your account ID
cp terraform.tfvars.example terraform.tfvars  # owner, emails
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
```

Confirm both SNS subscription emails (alerts, notifications).

## Seed demo users and run the end-to-end test

```bash
make seed PREFIX=yourname DOMAIN=gmail.com   # yourname+employee@, +manager@, +hr@ (plus-addressing)
make e2e
```

`seed` writes generated passwords to `.demo-users.json`, which is git-ignored. Never commit it.
`e2e` writes `docs/evidence/e2e-<timestamp>.md`.

## Dead-letter queues

An alarm `timesheet-dev-dlq-<name>` means an event could not be processed after 5 attempts
(pipe/delivery: after retries).

1. **Look:** `aws sqs receive-message --queue-url <dlq-url> --attribute-names All --max-number-of-messages 10`
2. **Find the cause:** the consumer's log group shows `"msg":"message failed"` with the error type and message ID.
3. **Decide:**
   - *Poison message* (malformed, or refers to a deleted item): delete it from the DLQ. Note it in the incident log.
   - *Transient or bug* (throttling, a fixed code defect): deploy the fix, then redrive:
     `aws sqs start-message-move-task --source-arn <dlq-arn>` (messages return to their source queue).
4. Consumers are idempotent, so a redrive can't double-count hours.

Practice it: `make dlq-drill`.

## Payroll

**Run on demand (HR):** `POST /hr/payroll-runs {"periodStart": "2026-10-12", "weeks": 1}`.
Status and the 5-minute download link: `GET /hr/payroll-runs/2026-10-12`.

**Scheduled:** set `payroll_schedule_enabled = true`. It runs Mondays 06:00 New York time for the previous week.

**A run failed** (alarm `payroll-failed`, or run status `FAILED`):

1. Step Functions console → the execution → the red state shows the error.
2. Common causes: an approved timesheet whose employee has no profile (HR must create one), or a
   timesheet changed after collection.
3. Fix the cause, then start the run again. The period is no longer `RUNNING`, so the lock allows it.
   Already-paid weeks are skipped.

**A run is stuck `RUNNING`** (execution aborted from the console, so the catch never ran):

```bash
aws dynamodb update-item --table-name timesheet-dev --key '{"PK":{"S":"PAYROLL#2026-10-12"},"SK":{"S":"RUN"}}' \
  --update-expression 'SET #s = :f' --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":f":{"S":"FAILED"}}'
```

## Replaying events

To rebuild a consumer's state (for example, after a bug in the ledger), replay the archive into
the bus. Consumers skip events they've already processed:

```bash
make replay-drill   # last hour; archived events can take a few minutes to become replayable
```

## Accidental data change

Point-in-time restore to a **new** table, then copy back the items you need:

```bash
aws dynamodb restore-table-to-point-in-time --source-table-name timesheet-dev \
  --target-table-name timesheet-dev-restore --restore-date-time <ISO time before the change>
```

## Teardown

```bash
echo 'deletion_protection = false' >> infra/environments/dev/terraform.tfvars
terraform -chdir=infra/environments/dev apply
terraform -chdir=infra/environments/dev destroy
```
