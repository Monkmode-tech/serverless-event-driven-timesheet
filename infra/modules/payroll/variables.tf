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

variable "exports_bucket" {
  description = "Exports bucket name."
  type        = string
}

variable "exports_bucket_arn" {
  description = "Exports bucket ARN."
  type        = string
}

variable "bus_name" {
  description = "Event bus for PayrollCompleted / PayrollFailed."
  type        = string
}

variable "bus_arn" {
  description = "Event bus ARN."
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

variable "schedule_enabled" {
  description = "Run payroll automatically every Monday for the previous week."
  type        = bool
  default     = false
}
