###############################################################################
# Cognito user pool: internal staff only (no self sign-up), three groups that
# map to the app's roles. API Gateway validates access tokens; the app reads
# `cognito:groups` from them for role-based authorization.
###############################################################################

resource "aws_cognito_user_pool" "this" {
  name                     = var.name
  deletion_protection      = var.deletion_protection ? "ACTIVE" : "INACTIVE"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 3
  }

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  username_configuration {
    case_sensitive = false
  }
}

resource "aws_cognito_user_group" "this" {
  for_each = {
    employees = "Submit and view own timesheets"
    managers  = "Approve or reject timesheets of direct reports"
    hr        = "Manage employee profiles and pay rates, run payroll"
  }

  user_pool_id = aws_cognito_user_pool.this.id
  name         = each.key
  description  = each.value
}

resource "aws_cognito_user_pool_client" "app" {
  name         = "${var.name}-app"
  user_pool_id = aws_cognito_user_pool.this.id

  # Public client (SPA / CLI): no secret. SRP keeps the password off the wire;
  # USER_PASSWORD_AUTH is only for the lab's scripted end-to-end test.
  generate_secret = false
  explicit_auth_flows = concat(
    ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"],
    var.enable_password_auth_for_tests ? ["ALLOW_USER_PASSWORD_AUTH"] : [],
  )

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 12
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
}
