# mcropsey Lab — Automated Deployment

VAmPI (intentionally vulnerable API) behind an F5 BIG-IP VE, in AWS `us-east-2`.
Four scripts replace the manual CLI + tmsh walkthrough in your existing docs.

> ⚠ VAmPI is deliberately vulnerable (OWASP API Top 10). Every security group
> here is locked to your `/32`. Never widen that to `0.0.0.0/0`.

---

## Quick start

```bash
cd mcropsey-lab
./01-deploy-aws.sh      # ~8 min  — CloudFormation stack, VAmPI + k3s come up
./02-configure-f5.sh    # ~10 min — waits for BIG-IP boot, applies all tmsh config
./03-verify.sh          # ~1 min  — end-to-end checks (VIP working, pool green)
# …lab work…
./99-teardown.sh        # deletes everything, releases Elastic IPs
```

Total wall time from nothing to a working VIP: roughly 20–25 minutes, most of
it waiting on the BIG-IP to license and provision itself.

**NoName remote engine is a separate post-deployment step** — see
`docs/noname-engine.md`. It requires manual work in the NoName portal first
(registering the engine to get credentials), then a Helm deploy on the k3s
node, then wiring the F5 clone pool. Do not attempt it until `03-verify.sh`
passes cleanly.

---

## Files

| File | What it does |
|---|---|
| `lab.env` | Region, stack name, key name, instance types. Edit here, not in the scripts. |
| `mcropsey-lab.yaml` | CloudFormation template — VAmPI, F5 BIG-IP, and k3s node. |
| `01-deploy-aws.sh` | Preflight → resolve AMIs → create stack → wait for VAmPI + k3s → write `lab-outputs.env`. |
| `02-configure-f5.sh` | SSH to BIG-IP → set password → VLANs, self IPs, routes (including k3s subnet), monitor, pool, virtual server → verify pool is green. |
| `03-verify.sh` | Checks AWS state, VAmPI direct, the VIP path, TMUI, pool health, and k3s node. |
| `99-teardown.sh` | Deletes the stack, then hunts for orphaned Elastic IPs and security groups. |
| `lab-outputs.env` | Generated at deploy time. All the live IPs — scripts 02/03/99 read it. |

### `docs/` — corrected reference material

| File | Was | Changed |
|---|---|---|
| `mcropsey-f5-vampi-setup-v3.docx` | `…setupv2.docx` | Management interface moved to `10.0.7.0/24`; routing section corrected and expanded; stale IPs removed |
| `f5tmshconfig.md` | same name | Default-gateway step added; IPs now read from `lab-outputs.env`; NoName clone pool section added |
| `README-cloudformation.md` | `README.md` | RHEL AMI filter fixed; preflight checks and failure diagnostics added |
| `lab-ips.md` | `currentipinfo.md` | Dead addresses replaced with instructions for reading live ones |
| `noname-engine.md` | *(new)* | Full NoName remote engine deployment: NGINX ingress, disk sizing, correct `custom_values.yaml` structure, helm install, F5 clone pool wiring |
| `f5-hsl-integration.md` | *(new)* | F5 HSL over HTTPS integration: complete traffic flow, all F5 objects (pools, VS, iRule), k3s catch-all ingress, nats-jetstream CPU fix, verification and troubleshooting |
| `f5-prevention-integration.md` | *(new)* | F5 Prevention integration: data groups, Noname-Prevention iRule, dual-iRule attachment order, data group population verification |

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

**`exists()` now matches both BIG-IP "not found" error formats.** The original
`exists()` helper checked for `"was not found"` to detect a missing object, but
`list net route <name>` returns `"route not found: <name>"` — no `"was"`. The
mismatch caused the route existence check to return true when the route was
absent, so `ensure` never called `create`. Both TMM routes (VAmPI subnet and
default gateway) were silently skipped, which is why the pool member showed
offline despite all other config being correct. The pattern now matches `"not
found"`, which covers both error formats.

**SSH calls no longer consume piped stdin before password prompts.** The BIG-IP
boot-wait loop runs multiple SSH connections before the `read` password prompt.
When the script is driven non-interactively (e.g.
`printf 'pass\npass\n' | ./02-configure-f5.sh`), those SSH connections drain
the pipe before `read` can see it, causing an immediate exit. `</dev/null` is
now set on every SSH call in the script.

**Everything is re-runnable.** `02` checks each object before creating it, so
if the pool member isn't green you can fix the cause and run it again without
tearing anything down.

---

## Troubleshooting

**Pool member won't go green.** In order of likelihood:

1. TMM route to VAmPI subnet is missing. Confirm with `list net route to-vampi` on the BIG-IP. If absent, create it: `create net route to-vampi network 10.0.1.0/24 gw 10.0.6.1`. Check for the default gateway too: `list net route` — you need a `default` entry; if not, `create net route default-gw network default gw 10.0.5.1`.
2. VAmPI container isn't running — `ssh -i ~/.ssh/mcropsey-key.pem ec2-user@<VAMPI_IP>`, then `sudo podman ps -a` and `sudo podman logs vampi`.
3. The container didn't start with `--network host`. Podman's default pasta networking silently drops VPC-to-VPC traffic.
4. Test the path from the BIG-IP itself:
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

## NoName remote engine

**Prerequisite: `03-verify.sh` must pass before starting this.**

The remote engine deployment has three phases — see `docs/noname-engine.md`
for the full walkthrough:

1. **NoName portal (manual)** — Register the engine in the UI to generate
   `engine_id`, certificates, and encoded keys. You must do this yourself;
   these credentials are what populate `custom_values.yaml`.

2. **k3s node (Helm)** — Once you have the credentials, deploy the chart:
   ```bash
   ssh -i ~/.ssh/mcropsey-key.pem ec2-user@$K3S_PUBLIC_IP
   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
   helm upgrade --install akamai-api-security \
     oci://us-central1-docker.pkg.dev/noname-artifacts/nns-docker/helm/nonamesec \
     -n akamai-api-security --create-namespace \
     -f ~/custom_values.yaml --version 'v3.69.0' --timeout 15m
   ```

3. **F5 clone pool** — After the engine shows connected in the portal:
   ```bash
   ssh -i ~/.ssh/mcropsey-key.pem admin@$F5_MGMT_IP
   # (inside tmsh)
   create ltm pool noname-mirror-pool members add { 10.0.8.100:4789 { address 10.0.8.100 } }
   modify ltm virtual vampi-vs clone-pools add { noname-mirror-pool { bind ingress } }
   save sys config
   ```

---

## Cost

Roughly **$1.00–1.10/hour** while running — the `m5.4xlarge` for the k3s node
dominates (~$0.77/hr), followed by the F5 `m5.xlarge` (~$0.19/hr). About
$24–26/day if you leave it up. `99-teardown.sh` releases all four Elastic IPs,
which are billed even when unassociated.

| Instance | Type | Cost/hr |
|---|---|---|
| F5 BIG-IP | m5.xlarge | ~$0.19 |
| VAmPI | t3.medium | ~$0.04 |
| k3s node | m5.4xlarge | ~$0.77 |
| 4 Elastic IPs | — | ~$0.015 |
