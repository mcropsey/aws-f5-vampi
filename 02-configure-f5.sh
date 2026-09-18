#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 02 — Configure the BIG-IP over the iControl REST API
#      VLANs, self IPs, routes, monitor, pool, virtual server.
#
#   ./02-configure-f5.sh
#   F5_ADMIN_PASSWORD='...' ./02-configure-f5.sh      # non-interactive
#
# Everything that configures traffic objects goes through https://<mgmt>/mgmt/tm/*.
# SSH is used for exactly one thing: setting the admin password on first boot,
# because REST authentication cannot happen until a password exists. After that
# the script never shells in again.
#
# Safe to re-run: every object is GET-checked before it is POSTed, and existing
# objects are PATCHed toward the desired state.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lab.env
source ./lab.env
# shellcheck source=/dev/null
[[ -f "$OUTPUTS_FILE" ]] || { echo "Missing $OUTPUTS_FILE — run ./01-deploy-aws.sh first." >&2; exit 1; }
source "./$OUTPUTS_FILE"

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hd=$'\033[1;36m'; c_0=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_ok"   "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_warn" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_err"  "$c_0" "$*" >&2; exit 1; }
hd()   { printf '\n%s── %s %s\n' "$c_hd" "$*" "$c_0"; }

command -v jq >/dev/null || die "jq is required. brew install jq"
[[ -f "$KEY_FILE" ]] || die "Private key not found at $KEY_FILE — needed for the one-time password bootstrap."

MGMT="https://${F5_MGMT_IP}"

SSH_OPTS=(-i "$KEY_FILE"
          -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR
          -o ConnectTimeout=10
          -o BatchMode=yes)

# ── 1. wait for the management plane ────────────────────────────────────────
# The REST framework (restjavad/icrd) comes up after tmm, so poll REST itself
# rather than SSH — that is the interface the rest of this script needs.
hd "Waiting for BIG-IP REST API at ${F5_MGMT_IP}"
say "First boot takes 5–10 minutes (licensing + provisioning). Be patient."

rest_up=0
for i in $(seq 1 60); do
  # /mgmt/shared/echo needs no auth once the framework is listening. A 401 on
  # /mgmt/tm/sys is just as good a signal: the endpoint exists and is enforcing.
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${MGMT}/mgmt/shared/echo" 2>/dev/null || true)
  if [[ "$code" == "200" || "$code" == "401" ]]; then rest_up=1; break; fi
  printf '  … waiting for REST framework (%d/60) [%s]\r' "$i" "${code:-no-response}"; sleep 20
done
say ""
[[ "$rest_up" == 1 ]] || die "BIG-IP REST API never answered on ${MGMT}.
      Check: the instance is running, your public IP still matches the
      security group rule (${MY_IP}/32), and ~10 min have passed since launch."
ok "REST framework is answering"

# ── 2. admin password (the one SSH step) ────────────────────────────────────
# REST auth needs a password; the AWS image ships without one. Set it via tmsh
# over SSH once, then everything else is REST.
hd "Admin password"

if [[ -z "${F5_ADMIN_PASSWORD:-}" ]]; then
  say "Required for iControl REST authentication and the TMUI login."
  read -r -s -p "Set admin password: " PW1 </dev/tty; say ""
  read -r -s -p "Confirm: "           PW2 </dev/tty; say ""
  [[ "$PW1" == "$PW2" ]] || die "Passwords did not match."
  [[ -n "$PW1" ]]        || die "Password cannot be empty — REST auth requires one."
  F5_ADMIN_PASSWORD="$PW1"
  unset PW1 PW2
else
  ok "Using F5_ADMIN_PASSWORD from the environment"
fi

# Probe /mgmt/tm/sys/version with basic auth.
#
# Three outcomes matter and they are easy to confuse:
#   200 — tm backend is up and the password works
#   401 — tm backend is up, password is wrong or not yet set
#   503 — the REST framework is listening but restjavad/icrd behind /mgmt/tm/*
#         has not finished starting. A timing state, NOT an auth failure, and it
#         persists for minutes after /mgmt/shared/echo starts answering.
#   404 — also transient: icrd registers its endpoint tree progressively, so
#         there is a window where the framework answers but /mgmt/tm/sys/version
#         is not mounted yet. Observed on 17.1.3.5 between the 503 and 200
#         phases. Treating it as fatal aborts the script seconds before the
#         device is ready.
# Only 200 and 401 are verdicts; everything else means "ask again".
tm_probe() {
  local tries="${1:-1}" i code
  for ((i=1; i<=tries; i++)); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
             -u "admin:${F5_ADMIN_PASSWORD}" "${MGMT}/mgmt/tm/sys/version" 2>/dev/null || true)
    [[ "$code" == "200" || "$code" == "401" ]] && { printf '%s' "$code"; return; }
    (( i < tries )) && { printf '  … tm backend still starting (%d/%d) [%s]\r' "$i" "$tries" "$code" >&2; sleep 15; }
  done
  printf '%s' "$code"
}

probe=$(tm_probe 1)

if [[ "$probe" == "200" ]]; then
  ok "Password already accepted by the REST API — skipping SSH bootstrap"
else
  say "Bootstrapping the password over SSH (one time only)…"
  booted=0
  for i in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" "admin@${F5_MGMT_IP}" "show sys version" </dev/null >/dev/null 2>&1; then
      booted=1; TMSH_PREFIX=""; break
    fi
    if ssh "${SSH_OPTS[@]}" "admin@${F5_MGMT_IP}" "tmsh -c 'show sys version'" </dev/null >/dev/null 2>&1; then
      booted=1; TMSH_PREFIX="tmsh -c "; break
    fi
    printf '  … waiting for SSH (%d/30)\r' "$i"; sleep 20
  done
  say ""
  [[ "$booted" == 1 ]] || die "Could not SSH to the BIG-IP to set the admin password."

  # Single-quote the password inside the remote tmsh command so shell
  # metacharacters in it are not reinterpreted on the far side.
  esc=${F5_ADMIN_PASSWORD//\'/\'\\\'\'}
  res=$(ssh "${SSH_OPTS[@]}" "admin@${F5_MGMT_IP}" \
          "${TMSH_PREFIX}modify auth user admin password '${esc}'" </dev/null 2>&1 || true)

  # Wait out restjavad/icrd startup (up to ~10 min) before judging the result.
  say "Waiting for the /mgmt/tm backend to accept requests…"
  probe=$(tm_probe 40)
  say ""
  case "$probe" in
    200) ok "Admin password set and accepted by the REST API" ;;
    401) die "REST auth returns 401 — the password was not accepted.
      BIG-IP enforces complexity: use a longer mixed-case password with a digit
      and a symbol, then re-run. BIG-IP said: ${res}" ;;
    503|404) die "The /mgmt/tm backend still returns ${probe} after ~10 minutes.
      restjavad/icrd has not finished starting. Check on the device:
        ssh -i ${KEY_FILE} admin@${F5_MGMT_IP}
        run util bash -c 'tmsh show sys service restjavad; tail -50 /var/log/restjavad.0.log'
      Then re-run this script — it is safe to re-run." ;;
    *)   die "Unexpected HTTP ${probe} from ${MGMT}/mgmt/tm/sys/version.
      BIG-IP said: ${res}" ;;
  esac
fi

# ── 3. auth token ───────────────────────────────────────────────────────────
# Token auth (not basic) for the config calls: it is what the F5 docs recommend
# for automation, and it keeps the password out of every subsequent request.
hd "Authentication token"
tok_json=$(curl -sk --max-time 20 -X POST "${MGMT}/mgmt/shared/authn/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg u admin --arg p "$F5_ADMIN_PASSWORD" \
        '{username:$u,password:$p,loginProviderName:"tmos"}')" 2>/dev/null || true)

TOKEN=$(printf '%s' "$tok_json" | jq -r '.token.token // empty')
[[ -n "$TOKEN" ]] || die "Could not obtain an auth token.
      Response: $(printf '%s' "$tok_json" | head -c 400)"
ok "Token acquired"

# Default token lifetime is 1200s; the pool-health wait can outlive that.
curl -sk --max-time 15 -X PATCH "${MGMT}/mgmt/shared/authz/tokens/${TOKEN}" \
  -H 'Content-Type: application/json' -H "X-F5-Auth-Token: ${TOKEN}" \
  -d '{"timeout":"36000"}' >/dev/null 2>&1 \
  && ok "Token lifetime extended to 10h" \
  || warn "Could not extend token lifetime — continuing on the 20m default"

logout_token() {
  [[ -n "${TOKEN:-}" ]] && curl -sk --max-time 10 -X DELETE \
    "${MGMT}/mgmt/shared/authz/tokens/${TOKEN}" \
    -H "X-F5-Auth-Token: ${TOKEN}" >/dev/null 2>&1 || true
}
trap logout_token EXIT

# ── 4. REST helpers ─────────────────────────────────────────────────────────
# api <METHOD> <PATH> [JSON_BODY]
#
# Sets two globals rather than printing the body: API_CODE and API_BODY.
# Returning the body on stdout would force callers into $(...) command
# substitution, which runs in a subshell — so the API_CODE assignment would be
# discarded and callers would silently test a stale code from an earlier call.
API_CODE=""
API_BODY=""
api() {
  local method="$1" path="$2" body="${3:-}" tmp
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    API_CODE=$(curl -sk --max-time 60 -o "$tmp" -w '%{http_code}' -X "$method" "${MGMT}${path}" \
          -H 'Content-Type: application/json' -H "X-F5-Auth-Token: ${TOKEN}" -d "$body")
  else
    API_CODE=$(curl -sk --max-time 60 -o "$tmp" -w '%{http_code}' -X "$method" "${MGMT}${path}" \
          -H "X-F5-Auth-Token: ${TOKEN}")
  fi
  API_BODY=$(cat "$tmp"); rm -f "$tmp"
}

# Short message out of an F5 error body, for diagnostics.
api_msg() { printf '%s' "$API_BODY" | jq -r '.message // empty' 2>/dev/null | head -c 300; }

# Object names in URLs are folder-encoded: /Common/foo -> ~Common~foo
enc() { printf '~Common~%s' "$1"; }

# ensure <collection-path> <name> <json-body> <label>
# GET first; POST only when absent. Verified by re-GETting, never by parsing
# the create response — BIG-IP returns advisory messages that read like errors.
ensure() {
  local coll="$1" name="$2" body="$3" label="$4" post_code post_msg
  api GET "${coll}/$(enc "$name")"
  if [[ "$API_CODE" == "200" ]]; then
    warn "$label already exists — leaving it alone"
    return 0
  fi
  api POST "$coll" "$body"
  post_code="$API_CODE"; post_msg="$(api_msg)"
  # Authoritative check is the re-GET, not the POST code: BIG-IP returns
  # advisory messages on success that are shaped exactly like errors.
  api GET "${coll}/$(enc "$name")"
  [[ "$API_CODE" == "200" ]] && { ok "$label created"; return 0; }
  die "$label failed (POST HTTP ${post_code}): ${post_msg}"
}

# patch <path> <json-body> <label>
patch() {
  local path="$1" body="$2" label="$3"
  api PATCH "$path" "$body"
  if [[ "$API_CODE" == "200" ]]; then ok "$label"
  else warn "$label — HTTP ${API_CODE}: $(api_msg)"
  fi
}

# ── 5. system basics ────────────────────────────────────────────────────────
hd "System settings"
patch /mgmt/tm/sys/global-settings \
      "$(jq -nc --arg h "bigip1.${PREFIX}.lab" '{hostname:$h,guiSetup:"disabled"}')" \
      "Hostname set to bigip1.${PREFIX}.lab, setup wizard disabled"
patch /mgmt/tm/sys/ntp '{"servers":["pool.ntp.org"]}'            "NTP server set"
patch /mgmt/tm/sys/dns '{"nameServers":["8.8.8.8","8.8.4.4"]}'   "DNS resolvers set"

# ── 6. VLANs ────────────────────────────────────────────────────────────────
# eth1 -> interface 1.1 (external, 10.0.5.0/24)
# eth2 -> interface 1.2 (internal, 10.0.6.0/24)
hd "VLANs"
ensure /mgmt/tm/net/vlan external \
  '{"name":"external","interfaces":[{"name":"1.1","untagged":true}]}' \
  "VLAN 'external' (1.1 / eth1)"
ensure /mgmt/tm/net/vlan internal \
  '{"name":"internal","interfaces":[{"name":"1.2","untagged":true}]}' \
  "VLAN 'internal' (1.2 / eth2)"

# ── 7. Self IPs ─────────────────────────────────────────────────────────────
hd "Self IPs"
ensure /mgmt/tm/net/self self-ext \
  '{"name":"self-ext","address":"10.0.5.10/24","vlan":"external","allowService":"none"}' \
  "Self IP self-ext 10.0.5.10/24"
ensure /mgmt/tm/net/self self-int \
  '{"name":"self-int","address":"10.0.6.10/24","vlan":"internal","allowService":"default"}' \
  "Self IP self-int 10.0.6.10/24"

# ── 8. Routes ───────────────────────────────────────────────────────────────
# TMM has no route to VAmPI's or the k3s subnet by default — without these the
# pool member never goes green no matter what else is correct.
hd "Routes"
ensure /mgmt/tm/net/route to-vampi \
  '{"name":"to-vampi","network":"10.0.1.0/24","gw":"10.0.6.1"}' \
  "Route to VAmPI subnet 10.0.1.0/24 via 10.0.6.1"
ensure /mgmt/tm/net/route to-k3s \
  '{"name":"to-k3s","network":"10.0.8.0/24","gw":"10.0.6.1"}' \
  "Route to k3s subnet 10.0.8.0/24 via 10.0.6.1"

# Return traffic to internet clients needs a default gateway on the external
# side. DHCP sometimes supplies one already — only add it if nothing is there.
api GET /mgmt/tm/net/route
if printf '%s' "$API_BODY" | jq -e '.items[]? | select(.network=="default" or .network=="0.0.0.0/0")' >/dev/null 2>&1; then
  ok "Default route already present"
else
  ensure /mgmt/tm/net/route default-gw \
    '{"name":"default-gw","network":"default","gw":"10.0.5.1"}' \
    "Default route via 10.0.5.1 (external subnet gateway)"
fi

# ── 9. Monitor, pool, virtual server ────────────────────────────────────────
hd "Health monitor"
ensure /mgmt/tm/ltm/monitor/http vampi-monitor \
  "$(jq -nc '{
      name:"vampi-monitor",
      defaultsFrom:"/Common/http",
      interval:5, timeout:16,
      send:"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
      recv:"200 OK"
    }')" \
  "Monitor 'vampi-monitor'"

hd "Pool"
say "Pool member: ${VAMPI_PRIVATE_IP}:5000"
ensure /mgmt/tm/ltm/pool vampi-pool \
  "$(jq -nc --arg m "${VAMPI_PRIVATE_IP}:5000" --arg a "$VAMPI_PRIVATE_IP" '{
      name:"vampi-pool",
      monitor:"/Common/vampi-monitor",
      loadBalancingMode:"round-robin",
      members:[{name:$m,address:$a}]
    }')" \
  "Pool 'vampi-pool'"

hd "Virtual server"
ensure /mgmt/tm/ltm/virtual vampi-vs \
  "$(jq -nc '{
      name:"vampi-vs",
      destination:"/Common/10.0.5.10:80",
      ipProtocol:"tcp",
      profiles:[{name:"http"},{name:"tcp"}],
      sourceAddressTranslation:{type:"automap"},
      pool:"/Common/vampi-pool",
      vlansEnabled:true,
      vlans:["/Common/external"]
    }')" \
  "Virtual server 'vampi-vs' on 10.0.5.10:80"

# ── 10. Save ────────────────────────────────────────────────────────────────
hd "Saving configuration"
api POST /mgmt/tm/sys/config '{"command":"save"}'
[[ "$API_CODE" == "200" ]] && ok "Config saved to disk" || warn "Save returned HTTP ${API_CODE}: $(api_msg)"

# ── 11. Verify pool health ──────────────────────────────────────────────────
hd "Pool health"
say "Monitor needs a few seconds to mark the member up…"
POOL_STATS_PATH="/mgmt/tm/ltm/pool/$(enc vampi-pool)/members/stats"
green=0
for i in $(seq 1 12); do
  api GET "$POOL_STATS_PATH"
  if printf '%s' "$API_BODY" | jq -e '
        .entries // {} | to_entries[]
        | select(.value.nestedStats.entries["status.availabilityState"].description=="available")
      ' >/dev/null 2>&1; then
    green=1; break
  fi
  printf '  … waiting for member to go green (%d/12)\r' "$i"; sleep 10
done
say ""
if [[ "$green" == 1 ]]; then
  ok "Pool member ${VAMPI_PRIVATE_IP}:5000 is UP"
else
  warn "Pool member is not green yet. Current state:"
  api GET "$POOL_STATS_PATH"
  printf '%s' "$API_BODY" | jq -r '
    .entries // {} | to_entries[]
    | "    " + (.value.nestedStats.entries["nodeName"].description // "?")
      + "  state=" + (.value.nestedStats.entries["status.availabilityState"].description // "?")
      + "  " + (.value.nestedStats.entries["status.statusReason"].description // "")' 2>/dev/null
  say ""
  warn "Most common causes, in order:"
  say  "  1. TMM route to VAmPI subnet missing"
  say  "     curl -sk -H \"X-F5-Auth-Token: \$TOKEN\" ${MGMT}/mgmt/tm/net/route | jq '.items[].name'"
  say  "  2. VAmPI container isn't running → ssh -i $KEY_FILE ec2-user@${VAMPI_PUBLIC_IP}; sudo podman ps"
  say  "  3. VAmPI SG missing the 10.0.6.0/24 rule on port 5000"
  say  "  4. Container not started with --network host (pasta drops VPC traffic)"
fi

hd "BIG-IP configuration complete"
cat <<EOF
  TMUI      https://${F5_MGMT_IP}/           (admin / the password you just set)
  VIP       http://${F5_VIP_IP}/
  REST      ${MGMT}/mgmt/tm/
  SSH       ssh -i ${KEY_FILE} admin@${F5_MGMT_IP}

Next:  ./03-verify.sh
EOF
