# Lab IPs

> Replaces the old `currentipinfo.md`, whose addresses belonged to a lab that no
> longer exists. **Do not hand-edit this file.** `01-deploy-aws.sh` writes the
> live values to `lab-outputs.env` in the bundle root on every deploy; that file
> is the source of truth.

Print the current values:

```bash
source lab-outputs.env
cat <<EOF
VAmPI direct    http://${VAMPI_PUBLIC_IP}:5000/
Swagger UI      http://${VAMPI_PUBLIC_IP}:5000/ui/
VAmPI private   ${VAMPI_PRIVATE_IP}:5000     (F5 pool member)
VAmPI via VIP   http://${F5_VIP_IP}/
F5 TMUI         https://${F5_MGMT_IP}/
F5 SSH          ssh -i ${KEY_FILE} admin@${F5_MGMT_IP}
k3s SSH         ssh -i ${KEY_FILE} ec2-user@${K3S_PUBLIC_IP}
k3s private     ${K3S_PRIVATE_IP}            (k3s node primary IP)
NoName sensor   ${NONAME_SENSOR_IP}          (reserved secondary IP — give this to NoName)
EOF
```

Or straight from CloudFormation, if `lab-outputs.env` is gone:

```bash
aws cloudformation describe-stacks --stack-name mcropsey-lab --region us-east-2 \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
```

---

## Fixed addresses

These are set by the template and do not change between deploys:

| Resource | Address |
|---|---|
| VPC | `10.0.0.0/16` |
| VAmPI subnet | `10.0.1.0/24` |
| F5 external self IP | `10.0.5.10` |
| F5 internal self IP | `10.0.6.10` |
| F5 management | `10.0.7.20` |
| Virtual server | `10.0.5.10:80` |
| k3s subnet | `10.0.8.0/24` |
| k3s node primary IP | `10.0.8.171` (changes each deploy) |
| **NoName sensor IP** | **`10.0.8.100`** (reserved secondary — does not change) |

The four Elastic IPs (VAmPI direct, F5 management, F5 VIP, k3s node) and the
primary private addresses of VAmPI and k3s are assigned at deploy time and
differ every run. `10.0.8.100` is a reserved secondary IP on the k3s ENI —
assign this to the NoName sensor service so the F5 clone pool target never
changes between deploys.

---

## When your own IP changes

Every security group in this lab is locked to your workstation's `/32`. Move to
a different network — or let your ISP rotate you — and everything stops
answering. `03-verify.sh` detects this and prints the exact commands to fix it.
