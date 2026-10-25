#!/usr/bin/env bash
#
# Create three demo users (employee, manager, HR) with random passwords, put
# them in their Cognito groups, and have HR create their profiles.
# Passwords are written only to .demo-users.json (git-ignored).
#
# Usage: scripts/seed-users.sh <email-prefix> <email-domain>
#   e.g. scripts/seed-users.sh caleb.demo example.com  ->  caleb.demo+employee@example.com, ...

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_outputs

PREFIX="${1:?usage: seed-users.sh <email-prefix> <email-domain>}"
DOMAIN="${2:?usage: seed-users.sh <email-prefix> <email-domain>}"

new_password() { printf '%sAa1' "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"; }

create() { # create <role> <groups...>
  local role="$1"; shift
  local email="${PREFIX}+${role}@${DOMAIN}" password
  password="$(new_password)"
  aws cognito-idp admin-create-user --user-pool-id "$POOL_ID" --username "$email" \
    --user-attributes Name=email,Value="$email" Name=email_verified,Value=true \
    --message-action SUPPRESS >/dev/null 2>&1 || log "$email already exists - resetting its password"
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL_ID" --username "$email" \
    --password "$password" --permanent
  for g in "$@"; do
    aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL_ID" --username "$email" --group-name "$g"
  done
  local sub
  sub="$(aws cognito-idp admin-get-user --user-pool-id "$POOL_ID" --username "$email" \
    --query "UserAttributes[?Name=='sub'].Value | [0]" --output text)"
  jq -n --arg e "$email" --arg p "$password" --arg s "$sub" '{email: $e, password: $p, sub: $s}'
}

umask 077
jq -n --argjson emp "$(create employee employees)" \
      --argjson mgr "$(create manager employees managers)" \
      --argjson hr "$(create hr employees hr)" \
      '{employee: $emp, manager: $mgr, hr: $hr}' >"$USERS_FILE"
log "users written to ${USERS_FILE#"$ROOT"/} (git-ignored)"

HR_TOKEN="$(token hr)"
profile() { # profile <role> <name> <managerRole> <rateCents>
  api "$HR_TOKEN" PUT "/hr/employees/$(user_field "$1" sub)" \
    "$(jq -cn --arg n "$2" --arg m "$(user_field "$3" sub)" --argjson r "$4" \
      '{name: $n, department: "engineering", managerId: $m, hourlyRateCents: $r}')" | cut -d' ' -f1
}
log "employee profile: HTTP $(profile employee 'Demo Employee' manager 4000)"
log "manager profile:  HTTP $(profile manager 'Demo Manager' hr 6000)"
log "hr profile:       HTTP $(profile hr 'Demo HR' manager 5500)"
