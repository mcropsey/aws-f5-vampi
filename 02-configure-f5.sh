#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 02 — Configure the BIG-IP: VLANs, self IPs, routes, monitor, pool, virtual
#      server. Everything the lab guide does by hand, over SSH.
#
#   ./02-configure-f5.sh
#
# Safe to re-run: every object is checked before it is created.
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

[[ -f "$KEY_FILE" ]] || die "Private key not found at $KEY_FILE — cannot SSH to the BIG-IP."

SSH_OPTS=(-i "$KEY_FILE"
          -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR
          -o ConnectTimeout=10
          -o BatchMode=yes)

# The admin account on the BIG-IP AWS image lands directly in tmsh, so the
# remote command string IS a tmsh command. Older/modified images land in bash;
# TMSH_PREFIX absorbs that difference.
TMSH_PREFIX=""
tm() { ssh "${SSH_OPTS[@]}" "admin@${F5_MGMT_IP}" "${TMSH_PREFIX}$1" 2>&1; }

# ── 1. wait for the BIG-IP to finish booting ─────────────────────────────────
hd "Waiting for BIG-IP at ${F5_MGMT_IP}"
say "First boot takes 5–10 minutes (licensing + provisioning). Be patient."

booted=0
for i in $(seq 1 60); do
  if out=$(ssh "${SSH_OPTS[@]}" "admin@${F5_MGMT_IP}" "show sys version" 2>&1); then
    if printf '%s' "$out" | grep -qi 'BIG-IP\|Sys::Version'; then
      booted=1; break
    fi
    # Shell is bash, not tmsh
    if out=$(ssh "${SSH_OPTS[@]}" "admin@${F5_MGMT_IP}" "tmsh -c 'show sys version'" 2>&1) \
       && printf '%s' "$out" | grep -qi 'BIG-IP\|Sys::Version'; then
      TMSH_PREFIX="tmsh -c "; booted=1; break
    fi
  fi
  printf '  … waiting for SSH/tmsh (%d/60)\r' "$i"; sleep 20
done
say ""
[[ "$booted" == 1 ]] || die "BIG-IP never became reachable over SSH.
      Check: the instance is running, your public IP still matches the
      security group rule ($MY_IP/32), and ~10 min have passed since launch."
ok "BIG-IP is up and tmsh is answering"

# Config subsystem (MCP) can still be settling even once tmsh answers.
for i in $(seq 1 30); do
  if tm "show sys mcp-state" | grep -qi 'end-platform-id-received\|running'; then break; fi
  printf '  … waiting for config subsystem (%d/30)\r' "$i"; sleep 10
done
say ""
ok "Config subsystem ready"

# ── 2. admin password ────────────────────────────────────────────────────────
hd "Admin password"
say "Needed for the TMUI web login at https://${F5_MGMT_IP}/"
say "(SSH keeps using your key either way. Press Enter to skip.)"
read -r -s -p "New admin password: " PW1; say ""
if [[ -n "$PW1" ]]; then
  read -r -s -p "Confirm: " PW2; say ""
  [[ "$PW1" == "$PW2" ]] || die "Passwords did not match."
  res=$(tm "modify auth user admin password \"$PW1\"")
  if printf '%s' "$res" | grep -qi 'error\|fail'; then
    warn "Password change reported: $res"
    warn "BIG-IP enforces complexity — try a longer mixed-case password with a digit and symbol."
  else
    ok "Admin password set"
  fi
  unset PW1 PW2
else
  warn "Skipped — TMUI login will not work until you set it manually."
fi

# ── 3. helper: create only if absent ─────────────────────────────────────────
# $1 = 'list' command that proves existence, $2 = 'create' command, $3 = label
#
# Success is decided by re-listing the object, not by parsing the create
# output — BIG-IP emits numbered *warnings* (e.g. traffic-group-local-only on
# a standalone device) that look exactly like numbered errors.
exists() {
  local out
  out=$(tm "$1" || true)
  [[ -n "$out" ]] && ! printf '%s' "$out" | grep -qi 'was not found\|010200[0-9]'
}

ensure() {
  local check="$1" create="$2" label="$3" res
  if exists "$check"; then
    warn "$label already exists — leaving it alone"
    return 0
  fi
  res=$(tm "$create" || true)
  if exists "$check"; then
    ok "$label created"
    [[ -n "${res// /}" ]] && printf '    (BIG-IP said: %s)\n' "$(printf '%s' "$res" | tr '\n' ' ' | cut -c1-160)"
    return 0
  fi
  die "$label failed:
$res"
}

# ── 4. system basics ─────────────────────────────────────────────────────────
hd "System settings"
tm "modify sys global-settings hostname bigip1.mcropsey.lab" >/dev/null && ok "Hostname set"
tm "modify sys ntp servers add { pool.ntp.org }"              >/dev/null || true
tm "modify sys dns name-servers add { 8.8.8.8 8.8.4.4 }"      >/dev/null || true
ok "NTP + DNS set"

# ── 5. VLANs ─────────────────────────────────────────────────────────────────
# eth1 -> interface 1.1 (external, 10.0.5.0/24)
# eth2 -> interface 1.2 (internal, 10.0.6.0/24)
hd "VLANs"
ensure "list net vlan external" \
       "create net vlan external interfaces add { 1.1 { untagged } }" \
       "VLAN 'external' (1.1 / eth1)"
ensure "list net vlan internal" \
       "create net vlan internal interfaces add { 1.2 { untagged } }" \
       "VLAN 'internal' (1.2 / eth2)"

# ── 6. Self IPs ──────────────────────────────────────────────────────────────
hd "Self IPs"
ensure "list net self self-ext" \
       "create net self self-ext address 10.0.5.10/24 vlan external allow-service none" \
       "Self IP self-ext 10.0.5.10/24"
ensure "list net self self-int" \
       "create net self self-int address 10.0.6.10/24 vlan internal allow-service default" \
       "Self IP self-int 10.0.6.10/24"

# ── 7. Routes ────────────────────────────────────────────────────────────────
# The F5 internal subnet has no route to VAmPI's subnet by default.
hd "Routes"
ensure "list net route to-vampi" \
       "create net route to-vampi network 10.0.1.0/24 gw 10.0.6.1" \
       "Route to VAmPI subnet 10.0.1.0/24 via 10.0.6.1"

# Return traffic to internet clients needs a default gateway on the external
# side. DHCP sometimes creates one already — only add it if nothing is there.
if tm "list net route" | grep -q 'network default\|0.0.0.0/0'; then
  ok "Default route already present"
else
  ensure "list net route default-gw" \
         "create net route default-gw network default gw 10.0.5.1" \
         "Default route via 10.0.5.1 (external subnet gateway)"
fi

# ── 8. Monitor, pool, virtual server ─────────────────────────────────────────
hd "Health monitor"
ensure "list ltm monitor http vampi-monitor" \
       "create ltm monitor http vampi-monitor defaults-from http interval 5 timeout 16 send \"GET / HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n\" recv \"200 OK\"" \
       "Monitor 'vampi-monitor'"

hd "Pool"
say "Pool member: ${VAMPI_PRIVATE_IP}:5000"
ensure "list ltm pool vampi-pool" \
       "create ltm pool vampi-pool monitor vampi-monitor load-balancing-mode round-robin members add { ${VAMPI_PRIVATE_IP}:5000 { address ${VAMPI_PRIVATE_IP} } }" \
       "Pool 'vampi-pool'"

hd "Virtual server"
ensure "list ltm virtual vampi-vs" \
       "create ltm virtual vampi-vs destination 10.0.5.10:80 ip-protocol tcp profiles add { http { } tcp { } } source-address-translation { type automap } pool vampi-pool vlans-enabled vlans add { external }" \
       "Virtual server 'vampi-vs' on 10.0.5.10:80"
say "(A traffic-group-local-only warning here is normal on a standalone lab device.)"

# ── 9. Save ──────────────────────────────────────────────────────────────────
hd "Saving configuration"
tm "save sys config" >/dev/null && ok "Config saved to disk"

# ── 10. Verify pool health ───────────────────────────────────────────────────
hd "Pool health"
say "Monitor needs a few seconds to mark the member up…"
green=0
for i in $(seq 1 12); do
  status=$(tm "show ltm pool vampi-pool members")
  if printf '%s' "$status" | grep -qi 'Availability.*: available\|State.*: up'; then
    green=1; break
  fi
  printf '  … waiting for member to go green (%d/12)\r' "$i"; sleep 10
done
say ""
if [[ "$green" == 1 ]]; then
  ok "Pool member ${VAMPI_PRIVATE_IP}:5000 is UP"
else
  warn "Pool member is not green yet. Current state:"
  tm "show ltm pool vampi-pool members"
  say ""
  warn "Most common causes, in order:"
  say  "  1. VAmPI container isn't running   → ssh ec2-user@${VAMPI_PUBLIC_IP}; sudo podman ps"
  say  "  2. VAmPI SG missing the 10.0.6.0/24 rule on port 5000"
  say  "  3. Container not started with --network host (pasta drops VPC traffic)"
  say  "  Test the path from the BIG-IP directly:"
  say  "     ssh -i $KEY_FILE admin@${F5_MGMT_IP}"
  say  "     run util bash -c 'curl -sv --interface 10.0.6.10 http://${VAMPI_PRIVATE_IP}:5000/'"
fi

hd "BIG-IP configuration complete"
cat <<EOF
  TMUI      https://${F5_MGMT_IP}/           (admin / the password you just set)
  VIP       http://${F5_VIP_IP}/
  SSH       ssh -i ${KEY_FILE} admin@${F5_MGMT_IP}

Next:  ./03-verify.sh
EOF
