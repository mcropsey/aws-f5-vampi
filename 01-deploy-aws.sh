#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 01 — Deploy the AWS side of the mcropsey lab (VAmPI + F5 BIG-IP VE)
#
#   ./01-deploy-aws.sh
#
# Idempotent-ish: refuses to run if the stack already exists (run 99-teardown.sh
# first). Everything AWS-side is created by CloudFormation; BIG-IP internal
# config happens in 02-configure-f5.sh.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lab.env
source ./lab.env

# ── pretty output ────────────────────────────────────────────────────────────
c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_hd=$'\033[1;36m'; c_0=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_ok"   "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_warn" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_err"  "$c_0" "$*" >&2; exit 1; }
hd()   { printf '\n%s── %s %s\n' "$c_hd" "$*" "$c_0"; }

aws_() { aws --region "$REGION" "$@"; }

# ── 0. preflight ─────────────────────────────────────────────────────────────
hd "Preflight"

say "Environment: $PREFIX   Stack: $STACK_NAME   Region: $REGION"

command -v aws >/dev/null || die "aws CLI not found on PATH."
[[ -n "${PREFIX:-}" ]] || die "PREFIX is not set in lab.env."
[[ -f "$TEMPLATE" ]] || die "Template '$TEMPLATE' not found in $(pwd)."

CALLER=$(aws_ sts get-caller-identity --output json) \
  || die "AWS CLI is not authenticated for region $REGION."
ACCOUNT=$(printf '%s' "$CALLER" | sed -n 's/.*"Account": *"\([0-9]*\)".*/\1/p')
ARN=$(printf '%s' "$CALLER" | sed -n 's/.*"Arn": *"\([^"]*\)".*/\1/p')
ok "Authenticated as $ARN (account $ACCOUNT), region $REGION"

# Key pair must exist in AWS...
aws_ ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1 \
  || die "Key pair '$KEY_NAME' does not exist in $REGION.
      Create it with:
        aws ec2 create-key-pair --region $REGION --key-name $KEY_NAME \\
          --query KeyMaterial --output text > $KEY_FILE && chmod 400 $KEY_FILE"
ok "Key pair '$KEY_NAME' exists in AWS"

# ...and the private key must exist locally, or 02-configure-f5.sh can't SSH in.
if [[ -f "$KEY_FILE" ]]; then
  perms=$(stat -f '%Lp' "$KEY_FILE" 2>/dev/null || stat -c '%a' "$KEY_FILE")
  [[ "$perms" == "400" || "$perms" == "600" ]] || { chmod 400 "$KEY_FILE"; warn "Fixed permissions on $KEY_FILE"; }
  ok "Private key found at $KEY_FILE"
else
  warn "Private key NOT found at $KEY_FILE — the stack will deploy, but"
  warn "02-configure-f5.sh will not be able to SSH into the BIG-IP."
fi

# Stack must not already exist
if aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  status=$(aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" \
            --query 'Stacks[0].StackStatus' --output text)
  die "Stack '$STACK_NAME' already exists (status: $status).
      Run ./99-teardown.sh first, or pick a different STACK_NAME in lab.env."
fi
ok "No existing '$STACK_NAME' stack"

# Warn about leftovers from a previous hand-rolled run — these cause the
# stack to fail late (after ~10 min) with a duplicate-name error.
for sg in "${PREFIX}-vampi-sg" "${PREFIX}-bigip-sg" "${PREFIX}-k3s-sg"; do
  if aws_ ec2 describe-security-groups --filters "Name=group-name,Values=$sg" \
       --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -q '^sg-'; then
    die "A security group named '$sg' already exists outside CloudFormation.
      Delete it first (or rename GroupName in $TEMPLATE):
        aws ec2 --region $REGION delete-security-group --group-name $sg"
  fi
done
ok "No conflicting security groups"

# ── 1. your public IP ────────────────────────────────────────────────────────
hd "Your public IP"
MY_IP=""
for src in https://checkip.amazonaws.com https://ifconfig.me https://icanhazip.com; do
  MY_IP=$(curl -s --max-time 8 "$src" 2>/dev/null || true)
  MY_IP=${MY_IP//[$'\r\n ']/}
  [[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
  MY_IP=""
done
if [[ -z "$MY_IP" ]]; then
  read -r -p "Could not auto-detect your public IP. Enter it manually (a.b.c.d): " MY_IP
  MY_IP=${MY_IP//[$'\r\n ']/}
fi
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$MY_IP' is not a valid IPv4 address."
ok "Locking SSH/TMUI/VIP access to ${MY_IP}/32"
warn "If you are on a VPN or your ISP rotates your IP, re-run:"
say  "    aws ec2 --region $REGION authorize-security-group-ingress ..."

# ── 2. resolve AMIs ──────────────────────────────────────────────────────────
hd "Resolving AMIs"

F5_AMI=$(aws_ ec2 describe-images --owners 679593333241 \
  --filters 'Name=name,Values=*BIGIP*Good*25Mbps*' \
            'Name=architecture,Values=x86_64' \
            'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null || true)

if [[ -z "$F5_AMI" || "$F5_AMI" == "None" ]]; then
  die "No F5 BIG-IP VE 'GOOD 25Mbps' AMI visible to this account in $REGION.

      This almost always means the AWS Marketplace subscription is not accepted.
      Fix it in the console:
        1. https://console.aws.amazon.com/marketplace
        2. Search: F5 BIG-IP Virtual Edition - GOOD - PAYG 25Mbps
        3. Continue to Subscribe → Accept Terms (takes a few minutes to activate)
      Then re-run this script."
fi
F5_AMI_NAME=$(aws_ ec2 describe-images --image-ids "$F5_AMI" \
  --query 'Images[0].Name' --output text)
ok "F5 AMI:    $F5_AMI"
say "           $F5_AMI_NAME"

# NOTE: the README's 'RHEL-9*GA*' filter only matches the original 9.0.0
# release — Red Hat dropped "GA" from later minor-release AMI names. Match the
# whole RHEL-9 line instead and filter out the variants we don't want.
RHEL_AMI=$(aws_ ec2 describe-images --owners 309956199498 \
  --filters 'Name=name,Values=RHEL-9*_HVM*' \
            'Name=architecture,Values=x86_64' \
            'Name=state,Values=available' \
            'Name=root-device-type,Values=ebs' \
  --query 'reverse(sort_by(Images,&CreationDate))[?!contains(Name,`BETA`) && !contains(Name,`SAP`) && !contains(Name,`Access2`)] | [0].ImageId' \
  --output text 2>/dev/null || true)

if [[ -z "$RHEL_AMI" || "$RHEL_AMI" == "None" ]]; then
  warn "Broad RHEL 9 lookup found nothing — falling back to the README filter."
  RHEL_AMI=$(aws_ ec2 describe-images --owners 309956199498 \
    --filters 'Name=name,Values=RHEL-9*GA*' 'Name=architecture,Values=x86_64' 'Name=state,Values=available' \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null || true)
fi
[[ -n "$RHEL_AMI" && "$RHEL_AMI" != "None" ]] || die "Could not resolve a RHEL 9 AMI in $REGION."
RHEL_AMI_NAME=$(aws_ ec2 describe-images --image-ids "$RHEL_AMI" \
  --query 'Images[0].Name' --output text)
ok "RHEL 9 AMI: $RHEL_AMI"
say "           $RHEL_AMI_NAME"

# ── 3. validate + create ─────────────────────────────────────────────────────
hd "Validating template"
aws_ cloudformation validate-template --template-body "file://$TEMPLATE" >/dev/null \
  || die "Template failed validation."
ok "Template is valid"

hd "Creating stack '$STACK_NAME'"
say "This launches an m5.xlarge (F5) + a $VAMPI_INSTANCE_TYPE (VAmPI) and 3 Elastic IPs."
say "Rough cost: ~\$0.25–0.35/hour while running. Run ./99-teardown.sh when done."
say ""
read -r -p "Proceed? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || die "Aborted."

aws_ cloudformation create-stack \
  --stack-name "$STACK_NAME" \
  --template-body "file://$TEMPLATE" \
  --on-failure DELETE \
  --parameters \
    "ParameterKey=Prefix,ParameterValue=$PREFIX" \
    "ParameterKey=MyIP,ParameterValue=${MY_IP}/32" \
    "ParameterKey=KeyName,ParameterValue=$KEY_NAME" \
    "ParameterKey=F5AMI,ParameterValue=$F5_AMI" \
    "ParameterKey=VAmPIAMI,ParameterValue=$RHEL_AMI" \
    "ParameterKey=VAmPIInstanceType,ParameterValue=$VAMPI_INSTANCE_TYPE" \
    "ParameterKey=F5InstanceType,ParameterValue=$F5_INSTANCE_TYPE" \
    "ParameterKey=K3sInstanceType,ParameterValue=$K3S_INSTANCE_TYPE" \
  --query 'StackId' --output text

say ""
say "Waiting for stack creation (typically 3–5 minutes)…"
if ! aws_ cloudformation wait stack-create-complete --stack-name "$STACK_NAME"; then
  say ""
  warn "Stack creation did not complete. Most recent failures:"
  aws_ cloudformation describe-stack-events --stack-name "$STACK_NAME" \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
    --output text 2>/dev/null || true
  die "See the events above. (--on-failure DELETE means the partial stack rolls itself back.)"
fi
ok "Stack created"

# ── 4. capture outputs ───────────────────────────────────────────────────────
hd "Outputs"
aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table

out() {
  aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

{
  echo "# Generated by 01-deploy-aws.sh on $(date)"
  echo "PREFIX=\"$PREFIX\""
  echo "REGION=\"$REGION\""
  echo "STACK_NAME=\"$STACK_NAME\""
  echo "KEY_FILE=\"$KEY_FILE\""
  echo "MY_IP=\"$MY_IP\""
  echo "F5_AMI=\"$F5_AMI\""
  echo "RHEL_AMI=\"$RHEL_AMI\""
  echo "VAMPI_PUBLIC_IP=\"$(out VAmPIPublicIP)\""
  echo "VAMPI_PRIVATE_IP=\"$(out VAmPIPrivateIP)\""
  echo "F5_MGMT_IP=\"$(out F5MgmtIP)\""
  echo "F5_VIP_IP=\"$(out F5VIPEIP)\""
  echo "K3S_PUBLIC_IP=\"$(out K3sPublicIP)\""
  echo "K3S_PRIVATE_IP=\"$(out K3sPrivateIP)\""
  echo "NONAME_SENSOR_IP=\"10.0.8.100\""
} > "$OUTPUTS_FILE"

ok "Saved to $OUTPUTS_FILE"

# shellcheck source=/dev/null
source "./$OUTPUTS_FILE"

# ── 5. wait for VAmPI to answer ──────────────────────────────────────────────
hd "Waiting for VAmPI container"
say "cloud-init installs podman and pulls the image — usually 2–4 minutes."
vampi_up=0
for i in $(seq 1 40); do
  if curl -s --max-time 5 "http://${VAMPI_PUBLIC_IP}:5000/" >/dev/null 2>&1; then
    vampi_up=1; break
  fi
  printf '  … still starting (%d/40)\r' "$i"; sleep 15
done
say ""
if [[ "$vampi_up" == 1 ]]; then
  ok "VAmPI is answering on http://${VAMPI_PUBLIC_IP}:5000/"
  curl -s --max-time 10 "http://${VAMPI_PUBLIC_IP}:5000/createdb" >/dev/null 2>&1 \
    && ok "VAmPI database initialised" \
    || warn "Could not hit /createdb — do it manually later."
else
  warn "VAmPI did not respond within 10 minutes. Debug with:"
  say  "    ssh -i $KEY_FILE ec2-user@${VAMPI_PUBLIC_IP}"
  say  "    sudo podman ps -a && sudo podman logs vampi"
  say  "    sudo tail -50 /var/log/cloud-init-output.log"
fi

# ── 6. wait for k3s to answer ────────────────────────────────────────────────
hd "Waiting for k3s node"
say "cloud-init installs k3s — usually 2–4 minutes after instance launch."
k3s_up=0
for i in $(seq 1 24); do
  if ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes \
       "ec2-user@${K3S_PUBLIC_IP}" \
       "sudo systemctl is-active k3s" </dev/null >/dev/null 2>&1; then
    k3s_up=1; break
  fi
  printf '  … k3s still starting (%d/24)\r' "$i"; sleep 15
done
say ""
if [[ "$k3s_up" == 1 ]]; then
  ok "k3s is running on ${K3S_PUBLIC_IP}"
else
  warn "k3s did not come up within 6 minutes. Debug with:"
  say  "    ssh -i $KEY_FILE ec2-user@${K3S_PUBLIC_IP}"
  say  "    sudo systemctl status k3s"
  say  "    sudo tail -50 /var/log/cloud-init-output.log"
fi

# ── done ─────────────────────────────────────────────────────────────────────
hd "AWS side complete"
cat <<EOF
  VAmPI direct    http://${VAMPI_PUBLIC_IP}:5000/
  Swagger UI      http://${VAMPI_PUBLIC_IP}:5000/ui/
  VAmPI private   ${VAMPI_PRIVATE_IP}       <- F5 pool member
  F5 TMUI         https://${F5_MGMT_IP}/
  F5 SSH          ssh -i ${KEY_FILE} admin@${F5_MGMT_IP}
  F5 VIP          http://${F5_VIP_IP}/      <- not live until step 02
  k3s SSH         ssh -i ${KEY_FILE} ec2-user@${K3S_PUBLIC_IP}
  k3s private     ${K3S_PRIVATE_IP}         <- k3s node primary IP
  NoName sensor   10.0.8.100                <- convention only; NOT created by the
                                               template. Add by hand as a /32 --
                                               see docs/noname-engine.md

Next:  ./02-configure-f5.sh
       (BIG-IP needs 5–10 minutes to finish booting; the script waits for it.)
EOF
