# Cost

Everything is pay-per-use, so the bill tracks usage. That was the core argument of the CLCS 605
design, and this doc puts numbers on it. Prices are us-east-2 list prices, October 2026. Check the
[AWS Pricing Calculator](https://calculator.aws/) before relying on them.

## Fixed monthly cost (idle)

| Item | ≈ $/month |
|---|---|
| KMS customer-managed key | 1.00 |
| CloudWatch alarms (~15 standard × $0.10) | 1.50 |
| Dashboard (first 3 per account are free) | 0.00 |
| Cognito (Essentials tier; first 10,000 monthly active users free) | 0.00 |
| DynamoDB, S3, logs at lab volume | < 0.50 |
| **Total** | **≈ $3** |

## Variable cost per 1,000 API requests

| Component | Basis | $ per 1k requests |
|---|---|---|
| HTTP API | $1.00 per million | 0.00100 |
| Lambda requests | $0.20 per million | 0.00020 |
| Lambda compute | 512 MB × ~50 ms × $0.0000133334/GB-s (arm64) | 0.00033 |
| DynamoDB | ~1 write ($0.625/M) + ~2 reads ($0.125/M) per request | 0.00088 |
| **Total** | | **≈ $0.0024** (about $2.40 per million requests) |

The dashboard computes this live: the **"Estimated variable cost per 1,000 API requests"** widget
is CloudWatch metric math over the actual request, invocation, duration and capacity metrics. It
uses the same unit prices, in `infra/modules/observability`.

## Example: a 200-person company

| Activity per month | Volume | ≈ $ |
|---|---|---|
| API calls (submit, review, reports) | ~50,000 | 0.12 |
| Events (Pipe $0.40/M, bus $1.00/M, SQS ~3 requests/message at $0.40/M, consumer Lambdas) | ~2,000 | < 0.01 |
| Payroll runs (4 × ~1,200 Step Functions transitions at $0.025/1,000) | 4 | 0.12 |
| Exports in S3 / Glacier | KBs | < 0.01 |
| **Total including fixed** | | **≈ $3.30** |

A container- or server-based version of the same app would cost about $30+/month at minimum
(a load balancer alone is ~$16/month) before any traffic.

## Cost guardrails

- API stage throttling (50 rps / 100 burst) caps runaway or abusive traffic.
- Consumer concurrency is capped at 5 per queue, so an event storm can't scale out without limit.
- The $50 account budget alarm comes from the
  [bootstrap](https://github.com/Monkmode-tech/aws-secure-three-tier-platform/tree/main/bootstrap).
