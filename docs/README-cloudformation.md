# CloudFormation Deployment — Manual Reference

> **This is the manual path.** `01-deploy-aws.sh` does all of it, with preflight
> checks and AMI resolution built in. Use this document when you want to run the
> steps yourself or understand what the script is doing.

---

## AMI IDs — do not hardcode these

The original version of this file pinned two AMIs:

- `ami-035032ea878eca201` (RHEL 9)
- `ami-0a330553d7e1d3c3f` (F5 BIG-IP VE)

Both go stale. Resolve them at deploy time instead.

### F5 BIG-IP VE — GOOD 25Mbps

```bash
aws ec2 describe-images --owners 679593333241 \
  --filters 'Name=name,Values=*BIGIP*Good*25Mbps*' \
            'Name=architecture,Values=x86_64' \
            'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
  --output text --region us-east-2
```

Returns `None` → **the Marketplace subscription is not accepted.** The AMI is
invisible to your account until it is. Subscribe to *"F5 BIG-IP Virtual Edition
- GOOD - PAYG 25Mbps"* in the AWS Marketplace console, wait a few minutes for it
to activate, then try again. This is the only step in the whole lab that cannot
be scripted.

### RHEL 9

⚠ **The old filter in this file was broken.** It used:

```bash
--filters "Name=name,Values=RHEL-9*GA*"
```

Red Hat only put `GA` in the *original* 9.0.0 AMI names (`RHEL-9.0.0_HVM_GA-…`).
Later minor releases dropped it (`RHEL-9.4.0_HVM-…`), so that filter either pins
you to RHEL 9.0 forever or returns nothing at all. Use this instead:

```bash
aws ec2 describe-images --owners 309956199498 \
  --filters 'Name=name,Values=RHEL-9*_HVM*' \
            'Name=architecture,Values=x86_64' \
            'Name=state,Values=available' \
            'Name=root-device-type,Values=ebs' \
  --query 'reverse(sort_by(Images,&CreationDate))[?!contains(Name,`BETA`) && !contains(Name,`SAP`) && !contains(Name,`Access2`)] | [0].ImageId' \
  --output text --region us-east-2
```

---

## Before you deploy

**Key pair must exist in AWS *and* locally.** The stack references it by name;
you need the `.pem` to SSH into the BIG-IP afterwards.

```bash
aws ec2 describe-key-pairs --key-names mcropsey-key \
  --query 'KeyPairs[0].KeyName' --output text --region us-east-2
```

**No leftover security groups.** The template hardcodes `GroupName:
mcropsey-sg` and `mcropsey-f5-sg`. If either name already exists outside
CloudFormation, the stack fails *after* both instances have launched — about ten
minutes in. Check first:

```bash
aws ec2 describe-security-groups --region us-east-2 \
  --filters 'Name=group-name,Values=mcropsey-sg,mcropsey-f5-sg' \
  --query 'SecurityGroups[*].[GroupName,GroupId]' --output text
```

---

## Deploy

```bash
aws cloudformation create-stack \
  --stack-name mcropsey-lab \
  --template-body file://mcropsey-lab.yaml \
  --on-failure DELETE \
  --parameters \
    ParameterKey=MyIP,ParameterValue=$(curl -s https://checkip.amazonaws.com)/32 \
    ParameterKey=KeyName,ParameterValue=mcropsey-key \
    ParameterKey=F5AMI,ParameterValue=<F5_AMI_ID> \
    ParameterKey=VAmPIAMI,ParameterValue=<RHEL_AMI_ID> \
  --region us-east-2
```

`--on-failure DELETE` is worth adding — without it a failed stack sits in
`ROLLBACK_COMPLETE`, which you then have to delete by hand before retrying.

Watch it:

```bash
aws cloudformation wait stack-create-complete --stack-name mcropsey-lab --region us-east-2
aws cloudformation describe-stacks --stack-name mcropsey-lab \
  --query 'Stacks[0].Outputs' --output table --region us-east-2
```

If it fails, the events tell you why:

```bash
aws cloudformation describe-stack-events --stack-name mcropsey-lab --region us-east-2 \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output text
```

---

## What the stack creates

| | |
|---|---|
| VPC | `10.0.0.0/16` |
| VAmPI subnet | `10.0.1.0/24` (`mcropsey-public-a`) |
| F5 external | `10.0.5.0/24` — eth1, carries the VIP |
| F5 internal | `10.0.6.0/24` — eth2, pool traffic |
| F5 management | `10.0.7.0/24` — eth0, **isolated from VAmPI** |
| Instances | RHEL 9 running VAmPI in podman, m5.xlarge BIG-IP VE |
| Elastic IPs | VAmPI direct, F5 management, F5 VIP |

The management subnet being separate is deliberate. An earlier revision put
eth0 on `10.0.1.0/24` alongside VAmPI; sharing a subnet between BIG-IP
management and a pool member creates routing ambiguity that is genuinely
unpleasant to debug.

---

## After the stack completes

Everything AWS-side is done. The BIG-IP's internal configuration is not — that
is `02-configure-f5.sh`, or `docs/f5tmshconfig.md` if you are doing it by hand:

1. Set the admin password
2. Create VLANs, self IPs, **routes**, monitor, pool, virtual server

Note the routes. The original write-up omitted them, and the omission is the
most common cause of "pool is green but the VIP hangs".

---

## Teardown

```bash
aws cloudformation delete-stack --stack-name mcropsey-lab --region us-east-2
aws cloudformation wait stack-delete-complete --stack-name mcropsey-lab --region us-east-2
```

Then check for unassociated Elastic IPs — AWS bills those even when they are
attached to nothing:

```bash
aws ec2 describe-addresses --region us-east-2 \
  --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' --output text
```

`99-teardown.sh` does both, and prompts before releasing anything.
