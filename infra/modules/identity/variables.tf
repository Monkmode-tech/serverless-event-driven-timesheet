variable "name" {
  description = "Name prefix."
  type        = string
}

variable "deletion_protection" {
  description = "Protect the user pool from deletion."
  type        = bool
  default     = true
}

variable "enable_password_auth_for_tests" {
  description = "Allow USER_PASSWORD_AUTH so scripts can sign in non-interactively (lab only)."
  type        = bool
  default     = true
}
