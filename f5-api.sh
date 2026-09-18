#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# f5-api.sh — authenticated iControl REST calls against this lab's BIG-IP.
#
#   ./f5-api.sh GET  /mgmt/tm/net/vlan
#   ./f5-api.sh GET  /mgmt/tm/ltm/pool/~Common~vampi-pool/members/stats
#   ./f5-api.sh POST /mgmt/tm/sys/config '{"command":"save"}'
#   ./f5-api.sh PATCH /mgmt/tm/ltm/virtual/~Common~vampi-vs '{"description":"lab"}'
#
#   ./f5-api.sh token        # just print a token, for your own curl calls
#
# Reads F5_MGMT_IP from lab-outputs.env and the password from
# .f5-admin-password (or $F5_ADMIN_PASSWORD). Object names in paths are
# folder-encoded: /Common/foo -> ~Common~foo
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"
source ./lab.env
[[ -f "$OUTPUTS_FILE" ]] || { echo "Missing $OUTPUTS_FILE — run ./01-deploy-aws.sh first." >&2; exit 1; }
source "./$OUTPUTS_FILE"

if [[ -z "${F5_ADMIN_PASSWORD:-}" && -f .f5-admin-password ]]; then
  # shellcheck disable=SC1091
  set -a; source ./.f5-admin-password; set +a
fi
[[ -n "${F5_ADMIN_PASSWORD:-}" ]] || {
  echo "Set F5_ADMIN_PASSWORD, or create .f5-admin-password with F5_ADMIN_PASSWORD=..." >&2; exit 1; }

command -v jq >/dev/null || { echo "jq is required. brew install jq" >&2; exit 1; }

MGMT="https://${F5_MGMT_IP}"

get_token() {
  curl -sk --max-time 20 -X POST "${MGMT}/mgmt/shared/authn/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg p "$F5_ADMIN_PASSWORD" \
          '{username:"admin",password:$p,loginProviderName:"tmos"}')" \
    | jq -r '.token.token // empty'
}

TOKEN=$(get_token)
[[ -n "$TOKEN" ]] || { echo "Authentication to ${MGMT} failed." >&2; exit 1; }

# Revoke on exit — do not leave tokens valid on the device.
trap '[[ -n "${TOKEN:-}" ]] && curl -sk --max-time 10 -X DELETE \
  "${MGMT}/mgmt/shared/authz/tokens/${TOKEN}" \
  -H "X-F5-Auth-Token: ${TOKEN}" >/dev/null 2>&1 || true' EXIT

if [[ "${1:-}" == "token" ]]; then
  # Caller wants to reuse it, so do not revoke it on the way out.
  trap - EXIT
  printf '%s\n' "$TOKEN"
  exit 0
fi

METHOD="${1:-GET}"
PATH_="${2:-/mgmt/tm/sys/version}"
BODY="${3:-}"

if [[ -n "$BODY" ]]; then
  curl -sk --max-time 60 -X "$METHOD" "${MGMT}${PATH_}" \
    -H 'Content-Type: application/json' -H "X-F5-Auth-Token: ${TOKEN}" -d "$BODY" | jq .
else
  curl -sk --max-time 60 -X "$METHOD" "${MGMT}${PATH_}" \
    -H "X-F5-Auth-Token: ${TOKEN}" | jq .
fi
