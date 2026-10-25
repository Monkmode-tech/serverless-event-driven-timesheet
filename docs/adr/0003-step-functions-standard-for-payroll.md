# ADR 0003: Step Functions Standard workflow for payroll

- Status: Accepted
- Date: 2026-10

## Context

Payroll must be correct, auditable, safe to retry and impossible to run twice concurrently for a
period. It touches every approved timesheet in a week.

## Options

1. **One scheduled Lambda that does everything.** It has a 15-minute ceiling, no per-step retries or
   visibility, and a crash midway leaves unknown state.
2. **Step Functions Express.** Cheap and fast, but at-least-once with no execution history beyond
   logs. Wrong for money.
3. **Step Functions Standard.** Exactly-once workflow execution, 90 days of visual history,
   per-state retries with backoff and jitter, and direct DynamoDB/EventBridge integrations.

## Decision

Standard workflow: Collect → Lock → Map(calculate) → Export → Map(mark PAID) → Close → event. A
catch path marks the run FAILED and emits `PayrollFailed`.

## Consequences

- Cost is $0.025 per 1,000 state transitions, about $0.03 for a 200-person run.
- The execution history is visible to anyone with `states:GetExecutionHistory`, so the state
  carries **IDs and totals only**. Names and rates never enter it.
- Marking PAID uses direct DynamoDB integration (no Lambda) with a condition that makes retries no-ops.
- Inline Map works up to a few thousand employees. Beyond that, distributed Map over an S3 manifest
  (roadmap).
