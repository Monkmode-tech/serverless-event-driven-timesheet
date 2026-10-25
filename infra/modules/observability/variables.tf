variable "name" {
  description = "Name prefix."
  type        = string
}

variable "kms_key_arn" {
  description = "Application KMS key (alerts topic)."
  type        = string
}

variable "alert_email" {
  description = "Email for operational alarms. Empty = none."
  type        = string
  default     = ""
}

variable "api_id" {
  description = "HTTP API ID."
  type        = string
}

variable "api_memory_mb" {
  description = "API Lambda memory, for the cost estimate."
  type        = number
  default     = 512
}

variable "table_name" {
  description = "DynamoDB table name."
  type        = string
}

variable "state_machine_arn" {
  description = "Payroll state machine ARN."
  type        = string
}

variable "queue_names" {
  description = "Consumer queue names by consumer."
  type        = map(string)
}

variable "dlq_names" {
  description = "Dead-letter queue names by purpose."
  type        = map(string)
}

variable "function_names" {
  description = "Lambda names by role; must include \"api\"."
  type        = map(string)

  validation {
    condition     = contains(keys(var.function_names), "api")
    error_message = "function_names must include the api function."
  }
}
