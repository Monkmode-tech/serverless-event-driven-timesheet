variable "name" {
  description = "Name prefix."
  type        = string
}

variable "kms_key_arn" {
  description = "Application KMS key."
  type        = string
}

variable "table_name" {
  description = "DynamoDB table name."
  type        = string
}

variable "table_arn" {
  description = "DynamoDB table ARN."
  type        = string
}

variable "stream_arn" {
  description = "DynamoDB stream ARN."
  type        = string
}

variable "zip_path" {
  description = "Lambda deployment package."
  type        = string
}

variable "zip_hash" {
  description = "Deployment package hash."
  type        = string
}

variable "notification_email" {
  description = "Email subscribed to user notifications (lab stand-in for per-user SES email). Empty = none."
  type        = string
  default     = ""
}

variable "audit_retention_days" {
  description = "Retention of the event audit log."
  type        = number
  default     = 365
}
