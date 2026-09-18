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
NoName sensor   ${NONAME_SENSOR_IP}          (convention only — add by hand as a /32)
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
| **F5 HSL middle VS** | **`10.0.6.100:80`** (⚠ BIG-IP-internal only — see below) |
| k3s subnet | `10.0.8.0/24` |
| k3s node primary IP | `10.0.8.245` (changes each deploy) |
| **NoName sensor IP** | **`10.0.8.100`** (⚠ *not* reserved — must be added by hand, see below) |

The four Elastic IPs (VAmPI direct, F5 management, F5 VIP, k3s node) and the
primary private addresses of VAmPI and k3s are assigned at deploy time and
differ every run.

> ⚠ **`10.0.8.100` is a convention, not a reservation.** `mcropsey-lab.yaml` has
> no `NetworkInterfaces` block and never mentions this address, so CloudFormation
> does not create it — it was added to the k3s node's `eth0` by hand. It is
> "stable across deploys" only in the sense that the *convention* is stable;
> after a fresh deploy nothing is listening on it until you add it.
>
> Add it as a **`/32`**, never a `/24`: as a `/24` it becomes the primary address
> of `10.0.8.0/24`, flannel then SNATs all pod egress to it, and since the
> Elastic IP is associated only with the node's primary private IP, every
> pod→internet packet is silently dropped at the internet gateway. Exact
> commands, plus the SNAT rule and the systemd unit that restores it at boot,
> are in `docs/noname-engine.md` → "Sensor IP must not be primary".

> ⚠ **`10.0.6.100` is a BIG-IP virtual server, not an AWS address.** It is the
> TLS-terminating middle virtual server that wraps the plaintext HSL stream
> before it is sent to the engine on `10.0.8.100:443`. It exists only in the
> BIG-IP configuration — there is no ENI, secondary private IP or route for it
> in AWS, and none is needed, because the traffic both originates and terminates
> on the BIG-IP and never reaches the AWS fabric. Do not assign it to an
> interface. See `docs/f5-hsl-integration.md`.
>
> Note how close `10.0.6.100` (F5 middle VS) and `10.0.8.100` (engine sensor)
> look. Transposing them yields a pool that monitors healthy while all telemetry
> is silently discarded.

---

## When your own IP changes

Every security group in this lab is locked to your workstation's `/32`. Move to
a different network — or let your ISP rotate you — and everything stops
answering. `03-verify.sh` detects this and prints the exact commands to fix it.
