###############################################################################
# Data tier
#
# DynamoDB single table (on-demand):
#   EMP#<id>        PROFILE                 HR-owned profile incl. pay rate
#   EMP#<id>        WEEK#<monday>           a weekly timesheet
#   PROJECT#<code>  WEEK#<monday>           approved hours per project (ledger)
#   PAYROLL#<mon>   RUN                     latest payroll run for a period
#   PAYRUN#<run>    LINE#<employee>         one payroll line per employee
#   IDEMPOTENCY#<consumer>  <emp#week#vN>   processed-event markers (TTL)
# GSI1  MGR#<manager> / STATUS#..#WEEK#..   a manager's approval queue
# GSI2  STATUS#<status> / WEEK#..#EMP#..    payroll's "approved in period"
#
# The stream (NEW_IMAGE) feeds the EventBridge Pipe - see modules/events.
#
# S3 exports: payroll CSVs, KMS-encrypted, Standard -> Glacier after 90 days,
# kept 7 years (FLSA requires 3; company policy here is 7).
###############################################################################

resource "aws_dynamodb_table" "this" {
  name                        = var.name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "PK"
  range_key                   = "SK"
  deletion_protection_enabled = var.deletion_protection
  stream_enabled              = true
  stream_view_type            = "NEW_IMAGE"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "GSI1PK"
    type = "S"
  }

  attribute {
    name = "GSI1SK"
    type = "S"
  }

  attribute {
    name = "GSI2PK"
    type = "S"
  }

  attribute {
    name = "GSI2SK"
    type = "S"
  }

  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  # Payroll only needs keys; the calculate step re-reads each item consistently.
  global_secondary_index {
    name               = "GSI2"
    hash_key           = "GSI2PK"
    range_key          = "GSI2SK"
    projection_type    = "INCLUDE"
    non_key_attributes = ["employeeId", "weekStart"]
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }
}

#------------------------------------------------------------------------------
# Exports bucket
#------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_s3_bucket" "exports" {
  # checkov:skip=CKV_AWS_18: Access logging is a production follow-up; CloudTrail data events can cover reads
  # checkov:skip=CKV2_AWS_62: Nothing consumes event notifications
  # checkov:skip=CKV_AWS_144: Single-region lab; see docs/architecture.md for the DR note
  bucket        = "${var.name}-exports-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_versioning" "exports" {
  bucket = aws_s3_bucket.exports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "exports" {
  bucket                  = aws_s3_bucket.exports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id

  rule {
    id     = "payroll-retention"
    status = "Enabled"

    filter {
      prefix = "payroll/"
    }

    transition {
      days          = var.glacier_after_days
      storage_class = "GLACIER"
    }

    expiration {
      days = var.retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "exports" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.exports.arn, "${aws_s3_bucket.exports.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyUploadsWithoutTheAppKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.exports.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.kms_key_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "exports" {
  bucket = aws_s3_bucket.exports.id
  policy = data.aws_iam_policy_document.exports.json

  depends_on = [aws_s3_bucket_public_access_block.exports]
}
