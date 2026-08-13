#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 99 — Delete the stack and clean up anything left behind.
#   ./99-teardown.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

cd "$(dirname "$0")" || exit 1
# shellcheck source=lab.env
source ./lab.env

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_hd=$'\033[1;36m'; c_0=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_ok"   "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_warn" "$c_0" "$*"; }
hd()   { printf '\n%s── %s %s\n' "$c_hd" "$*" "$c_0"; }
aws_() { aws --region "$REGION" "$@"; }

hd "Teardown: $STACK_NAME ($REGION)"
if ! aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  warn "Stack '$STACK_NAME' does not exist — checking for orphans anyway."
else
  aws_ cloudformation describe-stack-resources --stack-name "$STACK_NAME" \
    --query 'StackResources[*].[ResourceType,LogicalResourceId]' --output table
  read -r -p "Delete all of the above? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { say "Aborted."; exit 0; }

  aws_ cloudformation delete-stack --stack-name "$STACK_NAME"
  say "Deleting (2–5 minutes)…"
  if aws_ cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"; then
    ok "Stack deleted"
  else
    warn "Delete did not complete cleanly. Failures:"
    aws_ cloudformation describe-stack-events --stack-name "$STACK_NAME" \
      --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
      --output text 2>/dev/null
  fi
fi

# Elastic IPs are the expensive orphan — AWS bills unassociated EIPs.
hd "Checking for unassociated Elastic IPs"
orphans=$(aws_ ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp,Tags[?Key==`Name`].Value|[0]]' \
  --output text 2>/dev/null)
if [[ -n "$orphans" ]]; then
  warn "Unassociated EIPs found (these still cost money):"
  printf '%s\n' "$orphans" | sed 's/^/  /'
  read -r -p "Release them? [y/N] " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    while read -r alloc _ _; do
      [[ -n "$alloc" ]] && aws_ ec2 release-address --allocation-id "$alloc" && ok "Released $alloc"
    done <<< "$orphans"
  fi
else
  ok "No unassociated Elastic IPs"
fi

hd "Checking for leftover security groups"
for sg in mcropsey-sg mcropsey-f5-sg; do
  id=$(aws_ ec2 describe-security-groups --filters "Name=group-name,Values=$sg" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  if [[ "$id" == sg-* ]]; then
    warn "Security group '$sg' ($id) still exists"
    aws_ ec2 delete-security-group --group-id "$id" 2>/dev/null \
      && ok "Deleted $sg" \
      || warn "Could not delete $sg — something is probably still attached to it"
  fi
done

rm -f "$OUTPUTS_FILE"
hd "Done"
say "The key pair '$KEY_NAME' was left in place — it is not managed by this stack."
