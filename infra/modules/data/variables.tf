variable "name" {
  description = "Table name and bucket prefix."
  type        = string
}

variable "kms_key_arn" {
  description = "Application KMS key."
  type        = string
}

variable "deletion_protection" {
  description = "Protect the table from deletion."
  type        = bool
  default     = true
}

variable "glacier_after_days" {
  description = "Days before payroll exports move to S3 Glacier Flexible Retrieval."
  type        = number
  default     = 90
}

variable "retention_days" {
  description = "Days payroll exports are kept (2,557 = 7 years)."
  type        = number
  default     = 2557
}

variable "force_destroy" {
  description = "Allow terraform destroy to empty the exports bucket (lab teardown)."
  type        = bool
  default     = true
}
