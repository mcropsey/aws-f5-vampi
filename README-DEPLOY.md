# mcropsey Lab — Automated Deployment

VAmPI (intentionally vulnerable API) behind an F5 BIG-IP VE, in AWS `us-east-2`.
Four scripts replace the manual CLI + tmsh walkthrough in your existing docs.

> ⚠ VAmPI is deliberately vulnerable (OWASP API Top 10). Every security group
> here is locked to your `/32`. Never widen that to `0.0.0.0/0`.

---

## Quick start

```bash
cd mcropsey-lab
./01-deploy-aws.sh      # ~5 min  — CloudFormation stack, VAmPI comes up
./02-configure-f5.sh    # ~10 min — waits for BIG-IP boot, applies all tmsh config
./03-verify.sh          # ~1 min  — end-to-end checks
# …lab work…
./99-teardown.sh        # deletes everything, releases Elastic IPs
```

Total wall time from nothing to a working VIP: roughly 15–20 minutes, most of
it waiting on the BIG-IP to license and provision itself.

---

## Files

| File | What it does |
|---|---|
| `lab.env` | Region, stack name, key name, instance types. Edit here, not in the scripts. |
| `mcropsey-lab.yaml` | CloudFormation template — **unchanged** from your original. |
| `01-deploy-aws.sh` | Preflight → resolve AMIs → create stack → wait for VAmPI → write `lab-outputs.env`. |
| `02-configure-f5.sh` | SSH to BIG-IP → set password → VLANs, self IPs, routes, monitor, pool, virtual server → verify pool is green. |
| `03-verify.sh` | Checks AWS state, VAmPI direct, the VIP path, TMUI, and pool health. |
| `99-teardown.sh` | Deletes the stack, then hunts for orphaned Elastic IPs and security groups. |
| `lab-outputs.env` | Generated at deploy time. All the live IPs — scripts 02/03/99 read it. |

### `docs/` — corrected reference material

| File | Was | Changed |
|---|---|---|
| `mcropsey-f5-vampi-setup-v3.docx` | `…setupv2.docx` | Management interface moved to `10.0.7.0/24`; routing section corrected and expanded; stale IPs removed |
| `f5tmshconfig.md` | same name | Default-gateway step added; IPs now read from `lab-outputs.env` |
| `README-cloudformation.md` | `README.md` | RHEL AMI filter fixed; preflight checks and failure diagnostics added |
| `lab-ips.md` | `currentipinfo.md` | Dead addresses replaced with instructions for reading live ones |

### `originals/` — your five files, byte-for-byte as uploaded

Kept so you can diff, and so nothing is lost if one of my corrections turns out
to be wrong for your environment.

---

## Prerequisites

1. **AWS CLI authenticated** for `us-east-2` — you have this.
2. **Key pair `mcropsey-key`** must exist in AWS *and* the private key at
   `~/.ssh/mcropsey-key.pem`. If you need a new one:
   ```bash
   aws ec2 create-key-pair --region us-east-2 --key-name mcropsey-key \
     --query KeyMaterial --output text > ~/.ssh/mcropsey-key.pem
   chmod 400 ~/.ssh/mcropsey-key.pem
   ```
3. **F5 Marketplace subscription accepted.** This is the one thing that can't be
   scripted. Without it the AMI is invisible to your account and `01` stops with
   instructions. Subscribe to *"F5 BIG-IP Virtual Edition - GOOD - PAYG 25Mbps"*
   in the AWS Marketplace console first.

---

## What changed from your original docs

**AMIs are resolved at runtime, not hardcoded.** Both `ami-035032ea878eca201`
(RHEL 9) and `ami-0a330553d7e1d3c3f` (F5) are passed as parameters resolved
fresh on every run, so the stale-AMI warning in your README stops mattering.

**The RHEL filter was fixed.** Your README used `RHEL-9*GA*`. Red Hat only put
`GA` in the *original* 9.0.0 AMI names — later minor releases dropped it, so
that filter pins you to RHEL 9.0 or returns nothing at all. `01` matches the
whole `RHEL-9*_HVM*` line and excludes BETA/SAP/Access2 variants, with your
original filter kept as a fallback.

**A default route gets added on the BIG-IP.** Your tmsh doc creates the route to
`10.0.1.0/24` but no default gateway. Return traffic to internet clients needs
one on the external side — DHCP usually supplies it, but `02` checks and adds
`default gw 10.0.5.1` if nothing is there. This is the difference between
"pool is green but curl to the VIP hangs" and a working lab.

**The Word doc put F5 management on VAmPI's subnet.** `mcropseyf5vampisetupv2.docx`
placed the mgmt ENI at `10.0.1.20` inside `mcropsey-public-a` — the same subnet
as the pool member. Your CloudFormation template had already moved past this
(its own description calls `10.0.7.0/24` "the correct subnet design"), so the
doc and the template disagreed. `docs/mcropsey-f5-vampi-setup-v3.docx` now
matches the template throughout.

**Preflight catches the failures that cost you 10 minutes.** The template
hardcodes `GroupName: mcropsey-sg` and `mcropsey-f5-sg`, so a leftover security
group from a previous run makes the stack fail *after* both instances have
launched. `01` checks for that up front, along with the key pair, the private
key file, an existing stack, and Marketplace subscription status.

**Object creation is verified by re-listing, not by parsing output.** BIG-IP
emits numbered *warnings* that look identical to numbered errors — the
`traffic-group-local-only` message on virtual server creation is the famous
one. Every `create` in `02` is confirmed with a follow-up `list`.

**Everything is re-runnable.** `02` checks each object before creating it, so
if the pool member isn't green you can fix the cause and run it again without
tearing anything down.

---

## Troubleshooting

**Pool member won't go green.** In order of likelihood:

1. VAmPI container isn't running — `ssh -i ~/.ssh/mcropsey-key.pem ec2-user@<VAMPI_IP>`, then `sudo podman ps -a` and `sudo podman logs vampi`.
2. The container didn't start with `--network host`. Podman's default pasta networking silently drops VPC-to-VPC traffic — this is the single most common cause of a red pool in this lab.
3. Test the path from the BIG-IP itself:
   ```
   ssh -i ~/.ssh/mcropsey-key.pem admin@<F5_MGMT_IP>
   run util bash -c 'curl -sv --interface 10.0.6.10 http://<VAMPI_PRIVATE_IP>:5000/'
   ```

**Pool is green but `curl http://<VIP>/` hangs.** Missing default route on the
external side. Check with `list net route` — you need a `default` entry via
`10.0.5.1`.

**Everything times out that used to work.** Your public IP changed. `03` checks
this explicitly and prints the exact `authorize-security-group-ingress` commands.

**`02` can't SSH in.** BIG-IP first boot genuinely takes 5–10 minutes; the
script waits up to 20. Beyond that, confirm the instance is running and that
your IP still matches the security group.

---

## Cost

Roughly **$0.25–0.35/hour** while running — the `m5.xlarge` for the BIG-IP is
most of it, plus the PAYG license and three Elastic IPs. About $6–8/day if you
leave it up. `99-teardown.sh` releases the Elastic IPs too, which are billed
even when unassociated.
