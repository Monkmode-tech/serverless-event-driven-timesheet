# ADR 0002: Events through a transactional outbox (DynamoDB Stream → EventBridge Pipe)

- Status: Accepted
- Date: 2026-10

## Context

Approving a timesheet must (a) persist the approval and (b) notify the employee and update project
totals. If the API writes to DynamoDB and *then* publishes an event, either step can fail alone.
The result would be approvals nobody hears about, or events for writes that never happened (the
dual-write problem).

## Options

1. **Write then publish from the Lambda.** Simple, but loses or invents events on partial failure.
2. **DynamoDB Stream → Lambda that publishes.** Correct, but it is custom glue code to own.
3. **DynamoDB Stream → EventBridge Pipe → event bus.** Correct, with no code. Filtering,
   transformation, retries, bisecting bad batches and a DLQ are configuration.
4. **SNS topic → SQS queues (fan-out).** Good for fan-out, but it doesn't solve the dual write,
   and content-based routing is weaker than EventBridge rules.

## Decision

Option 3, with EventBridge rules routing to **one SQS queue per consumer**. Queues add buffering,
per-consumer DLQs, independent retries and concurrency caps.

## Consequences

- An event exists if and only if the write committed.
- At-least-once delivery means consumers **must** be idempotent. Each one keys on
  `(employeeId, weekStart, version)`, and the ledger makes its marker and increments one transaction.
- The archive enables replay to rebuild or backfill a consumer. This is safe precisely because of idempotency.
- Event latency is roughly 1–2 s end to end (stream polling + batching). That's fine for
  notifications and reports, but the wrong pattern for anything a user waits on synchronously.
