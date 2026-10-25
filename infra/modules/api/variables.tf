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
  description = "Payroll exports bucket name."
  type        = string
}

variable "exports_bucket_arn" {
  description = "Payroll exports bucket ARN."
  type        = string
}

variable "payroll_state_machine_arn" {
  description = "Payroll state machine the API may start."
  type        = string
}

variable "user_pool_endpoint" {
  description = "Cognito user pool endpoint (issuer without https://)."
  type        = string
}

variable "client_id" {
  description = "Cognito app client ID (token audience)."
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

variable "reserved_concurrency" {
  description = "API Lambda reserved concurrency (-1 = unreserved)."
  type        = number
  default     = -1
}

variable "throttle_rate" {
  description = "Steady-state requests per second."
  type        = number
  default     = 50
}

variable "throttle_burst" {
  description = "Burst requests."
  type        = number
  default     = 100
}

variable "log_retention_days" {
  description = "Access log retention."
  type        = number
  default     = 30
}
