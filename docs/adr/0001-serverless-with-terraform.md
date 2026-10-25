# ADR 0001: Serverless on AWS, defined in Terraform (not SAM)

- Status: Accepted
- Date: 2026-10

## Context

The CLCS 605 design chose a serverless architecture for an internal timesheet system: spiky load
around payroll deadlines, near-zero load at night and on weekends, and a small team that can't run
servers. It proposed AWS SAM/CloudFormation for deployment.

## Decision

Keep the serverless architecture: API Gateway, Lambda, DynamoDB, plus EventBridge, SQS and Step
Functions for the asynchronous parts. Define it in **Terraform** rather than SAM.

## Why Terraform over SAM

- One tool across the whole portfolio and the AWS/Azure work, with the same state, review and
  scanning workflow (tflint, checkov) everywhere.
- Cognito, Pipes, Scheduler, KMS policies and alarms are first-class Terraform resources. In SAM
  they would be raw CloudFormation anyway.
- **Trade-off:** SAM's `sam local invoke` and built-in canary deployments (CodeDeploy) are more
  convenient. Here, local testing is done with plain unit tests and in-memory fakes, and canary
  releases are on the roadmap.

## Consequences

- Idle cost is about $3/month and scales per request ([docs/cost.md](../cost.md)).
- There are no servers to patch. The runtime (Python 3.12) is managed by Lambda, and its deprecation
  date is the upgrade trigger.
- Cold starts are possible. Functions are small (standard library only), so they add tens of
  milliseconds, inside the 300 ms p95 target.
