variable "project" {
  description = "Project name used in resource names."
  type        = string
  default     = "timesheet"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
}

variable "aws_region" {
  description = "Region."
  type        = string
  default     = "us-east-2"
}

variable "alert_email" {
  description = "Email for operational alarms. Empty = none."
  type        = string
  default     = ""
}

variable "notification_email" {
  description = "Email that receives the user notifications in the lab. Empty = none."
  type        = string
  default     = ""
}

variable "payroll_schedule_enabled" {
  description = "Run payroll automatically every Monday for the previous week."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Protect the table and user pool. Set false (and apply) before terraform destroy."
  type        = bool
  default     = true
}
