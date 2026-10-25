#!/usr/bin/env bash
# Shared helpers: Terraform outputs, Cognito sign-in, API calls.
# shellcheck disable=SC2034  # variables are used by the scripts that source this

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="${ENV_DIR:-$ROOT/infra/environments/dev}"
EVIDENCE_DIR="$ROOT/docs/evidence"
USERS_FILE="$ROOT/.demo-users.json"   # git-ignored: generated passwords live only here

need() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || { echo "missing dependency: $bin" >&2; exit 2; }
  done
}

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

load_outputs() {
  need terraform jq aws curl
  local out
  out="$(terraform -chdir="$ENV_DIR" output -json)"
  API_URL="$(jq -r '.api_url.value' <<<"$out")"
  POOL_ID="$(jq -r '.user_pool_id.value' <<<"$out")"
  CLIENT_ID="$(jq -r '.client_id.value' <<<"$out")"
  TABLE="$(jq -r '.table_name.value' <<<"$out")"
  BUS="$(jq -r '.event_bus.value' <<<"$out")"
  ARCHIVE="$(jq -r '.event_archive.value' <<<"$out")"
  NOTIFY_QUEUE="$(jq -r '.queues.value.consumers.notify' <<<"$out")"
  NOTIFY_DLQ="$(jq -r '.queues.value.dlqs.notify' <<<"$out")"
  REGION="$(jq -r '.region.value' <<<"$out")"
  export AWS_REGION="$REGION"
}

user_field() { jq -r --arg r "$1" --arg f "$2" '.[$r][$f]' "$USERS_FILE"; }

# Access token for a demo user (role: employee | manager | hr).
token() {
  aws cognito-idp initiate-auth --client-id "$CLIENT_ID" --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=$(user_field "$1" email),PASSWORD=$(user_field "$1" password)" \
    --query 'AuthenticationResult.AccessToken' --output text
}

# api <token> <METHOD> <path> [json-body]  -> prints "<status> <body>"
api() {
  local tok="$1" method="$2" path="$3" data="${4:-}" out status
  local args=(-s -w '\n%{http_code}' -X "$method" -H "authorization: Bearer $tok" "$API_URL$path")
  if [ -n "$data" ]; then args+=(-H 'content-type: application/json' --data "$data"); fi
  out="$(curl "${args[@]}")"
  status="$(tail -n1 <<<"$out")"
  echo "$status $(sed '$d' <<<"$out")"
}

last_monday() {
  # Monday of the previous week (GNU date, falls back to BSD/macOS date).
  date -u -d "last monday -7 days" +%F 2>/dev/null || date -u -v-mon -v-7d +%F
}
