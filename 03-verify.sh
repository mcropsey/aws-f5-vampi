#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 03 — End-to-end verification: AWS resources, VAmPI direct, F5 VIP path.
#   ./03-verify.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail   # deliberately not -e: we want every check to run

cd "$(dirname "$0")" || exit 1
# shellcheck source=lab.env
source ./lab.env
# shellcheck source=/dev/null
[[ -f "$OUTPUTS_FILE" ]] || { echo "Missing $OUTPUTS_FILE — run ./01-deploy-aws.sh first." >&2; exit 1; }
source "./$OUTPUTS_FILE"

c_ok=$'\033[32m'; c_err=$'\033[31m'; c_hd=$'\033[1;36m'; c_0=$'\033[0m'
pass=0; fail=0
hd()   { printf '\n%s── %s %s\n' "$c_hd" "$*" "$c_0"; }
check() { # $1 = label, $2 = command
  if eval "$2" >/dev/null 2>&1; then
    printf '%s✓%s %s\n' "$c_ok" "$c_0" "$1"; pass=$((pass+1))
  else
    printf '%s✗%s %s\n' "$c_err" "$c_0" "$1"; fail=$((fail+1))
  fi
}

printf '%sEnvironment: %s   Stack: %s%s\n' "$c_hd" "$PREFIX" "$STACK_NAME" "$c_0"

hd "AWS resources"
check "CloudFormation stack is healthy" \
  "[[ \$(aws --region $REGION cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].StackStatus' --output text) =~ ^(CREATE|UPDATE)_COMPLETE\$ ]]"
check "VAmPI instance running" \
  "[[ \$(aws --region $REGION ec2 describe-instances --filters Name=tag:Name,Values=${PREFIX}-vampi Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text) == i-* ]]"
check "F5 instance running" \
  "[[ \$(aws --region $REGION ec2 describe-instances --filters Name=tag:Name,Values=${PREFIX}-bigip Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text) == i-* ]]"
check "F5 has 3 network interfaces attached" \
  "[[ \$(aws --region $REGION ec2 describe-instances --filters Name=tag:Name,Values=${PREFIX}-bigip Name=instance-state-name,Values=running --query 'length(Reservations[0].Instances[0].NetworkInterfaces)' --output text) == 3 ]]"
check "k3s instance running" \
  "[[ \$(aws --region $REGION ec2 describe-instances --filters Name=tag:Name,Values=${PREFIX}-k3s Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text) == i-* ]]"

hd "Your public IP still matches the security groups"
NOW_IP=$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '\r\n ')
if [[ "$NOW_IP" == "$MY_IP" ]]; then
  printf '%s✓%s Public IP unchanged (%s)\n' "$c_ok" "$c_0" "$NOW_IP"; pass=$((pass+1))
else
  printf '%s✗%s Public IP changed: %s → %s — SG rules will block you.\n' "$c_err" "$c_0" "$MY_IP" "$NOW_IP"
  printf '    Fix with:\n'
  for sg in "${PREFIX}-vampi-sg" "${PREFIX}-bigip-sg" "${PREFIX}-k3s-sg"; do
    printf '      aws ec2 --region %s authorize-security-group-ingress --group-name %s --protocol tcp --port <22|80|443|5000> --cidr %s/32\n' "$REGION" "$sg" "$NOW_IP"
  done
  fail=$((fail+1))
fi

hd "VAmPI — direct"
check "http://${VAMPI_PUBLIC_IP}:5000/ responds"       "curl -sf --max-time 10 http://${VAMPI_PUBLIC_IP}:5000/"
check "Swagger UI at :5000/ui/ responds"               "curl -sf --max-time 10 http://${VAMPI_PUBLIC_IP}:5000/ui/"

hd "VAmPI — through the F5 VIP"
check "http://${F5_VIP_IP}/ responds"                  "curl -sf --max-time 10 http://${F5_VIP_IP}/"
check "/createdb through the VIP"                      "curl -sf --max-time 15 http://${F5_VIP_IP}/createdb"
check "/users/v1 returns data through the VIP"         "curl -sf --max-time 10 http://${F5_VIP_IP}/users/v1"

hd "F5 management"
check "TMUI at https://${F5_MGMT_IP}/ responds"        "curl -skf --max-time 15 https://${F5_MGMT_IP}/ -o /dev/null"

hd "Pool status (via iControl REST)"
if [[ -n "${F5_ADMIN_PASSWORD:-}" ]]; then
  TOKEN=$(curl -sk --max-time 20 -X POST "https://${F5_MGMT_IP}/mgmt/shared/authn/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg p "$F5_ADMIN_PASSWORD" \
          '{username:"admin",password:$p,loginProviderName:"tmos"}')" 2>/dev/null \
    | jq -r '.token.token // empty')
  if [[ -n "$TOKEN" ]]; then
    check "Virtual server 'vampi-vs' exists" \
      "curl -skf --max-time 15 -H 'X-F5-Auth-Token: $TOKEN' https://${F5_MGMT_IP}/mgmt/tm/ltm/virtual/~Common~vampi-vs"
    curl -sk --max-time 20 -H "X-F5-Auth-Token: $TOKEN" \
      "https://${F5_MGMT_IP}/mgmt/tm/ltm/pool/~Common~vampi-pool/members/stats" 2>/dev/null \
      | jq -r '.entries // {} | to_entries[]
          | "  " + (.value.nestedStats.entries["nodeName"].description // "?")
            + "  state=" + (.value.nestedStats.entries["status.availabilityState"].description // "?")
            + "  " + (.value.nestedStats.entries["status.statusReason"].description // "")' 2>/dev/null
    curl -sk --max-time 10 -X DELETE "https://${F5_MGMT_IP}/mgmt/shared/authz/tokens/${TOKEN}" \
      -H "X-F5-Auth-Token: ${TOKEN}" >/dev/null 2>&1 || true
  else
    printf '  (could not authenticate to the REST API)\n'
  fi
else
  printf '  (set F5_ADMIN_PASSWORD to check pool state over the API)\n'
fi

if [[ -f "$KEY_FILE" && -n "${K3S_PUBLIC_IP:-}" ]]; then
  hd "k3s node"
  check "k3s service active on ${K3S_PUBLIC_IP}" \
    "ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes ec2-user@${K3S_PUBLIC_IP} 'sudo systemctl is-active k3s' </dev/null"
  check "k3s node Ready" \
    "ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes ec2-user@${K3S_PUBLIC_IP} 'sudo /usr/local/bin/k3s kubectl get nodes --no-headers | grep -q Ready' </dev/null"
fi

hd "Result"
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
if [[ "$fail" -eq 0 ]]; then
  cat <<EOF
  Everything is live.

    VAmPI direct   http://${VAMPI_PUBLIC_IP}:5000/
    Swagger UI     http://${VAMPI_PUBLIC_IP}:5000/ui/
    F5 VIP         http://${F5_VIP_IP}/
    F5 TMUI        https://${F5_MGMT_IP}/
    k3s SSH        ssh -i ${KEY_FILE} ec2-user@${K3S_PUBLIC_IP:-<not deployed>}
    k3s private    ${K3S_PRIVATE_IP:-<not deployed>}

  Remember: ./99-teardown.sh when you're done — this lab bills ~\$1.00-1.10/hr.
EOF
else
  echo "  See the failures above. 02-configure-f5.sh is safe to re-run."
  exit 1
fi
