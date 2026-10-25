variable "name" {
  description = "Function (and role, log group) name."
  type        = string
}

variable "description" {
  description = "Function description."
  type        = string
}

variable "handler" {
  description = "Python handler, e.g. timesheet.api.handler."
  type        = string
}

variable "zip_path" {
  description = "Path of the deployment package."
  type        = string
}

variable "zip_hash" {
  description = "Base64 SHA-256 of the deployment package."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for the log group and environment variables."
  type        = string
}

variable "policy_json" {
  description = "Function-specific IAM policy (least privilege)."
  type        = string
}

variable "environment" {
  description = "Environment variables."
  type        = map(string)
  default     = {}
}

variable "memory_mb" {
  description = "Memory (CPU scales with it)."
  type        = number
  default     = 256
}

variable "timeout_seconds" {
  description = "Timeout."
  type        = number
  default     = 10
}

variable "reserved_concurrency" {
  description = "Reserved concurrency (-1 = unreserved)."
  type        = number
  default     = -1
}

variable "log_retention_days" {
  description = "Log retention."
  type        = number
  default     = 30
}
