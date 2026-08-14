# F5 BIG-IP Prevention — NoName Integration

> **Prerequisite order:**
> 1. `01-deploy-aws.sh` → `02-configure-f5.sh` → `03-verify.sh` (VIP working)
> 2. NoName remote engine deployed and connected (`docs/noname-engine.md`)
> 3. F5 HSL source integration complete (`docs/f5-hsl-integration.md`)
> 4. Then this document
>
> **Before you start — security group check (do this first):**
> The NoName engine writes block lists to the F5 management REST API. The F5
> management security group (`mcropsey-f5-sg`) must allow TCP 443 from the k3s
> subnet **before** you configure the integration, or the engine will never be
> able to push entries and blocks will silently not work.
> The CloudFormation template now includes this rule. If you are working with a
> stack deployed before this fix, add it manually:
> ```bash
> F5_SG=$(aws ec2 describe-security-groups --region us-east-2 \
>   --filters "Name=group-name,Values=mcropsey-f5-sg" \
>   --query 'SecurityGroups[0].GroupId' --output text)
> aws ec2 authorize-security-group-ingress --region us-east-2 \
>   --group-id $F5_SG --protocol tcp --port 443 --cidr 10.0.8.0/24
> ```
> Verify from the k3s node before going further:
> ```bash
> ssh -i ~/.ssh/mcropsey-key.pem ec2-user@$K3S_PUBLIC_IP \
>   "curl -sk -o /dev/null -w '%{http_code}' https://10.0.7.20/mgmt/tm/ltm/data-group/internal/noname_prevention_ip"
> # Must return 401 (unauthorized = reachable). 000 = still blocked.
> ```

The prevention integration allows the NoName / Akamai API Security platform to
actively block or rate-limit API traffic on the F5 BIG-IP. The `Noname-Prevention`
iRule checks inbound requests against four data groups that the NoName engine
populates dynamically — matching requests are blocked before they reach the
pool member.

---

## How it works

```
Client request → vampi-vs
                    │
                    ├── noname-hsl-https-logger  (captures traffic → engine)
                    │
                    └── Noname-Prevention        (checks request against data groups)
                              │
                    ┌─────────┴──────────┐
                    │  match found?      │
                   yes                  no
                    │                   │
                 block/reject       forward to
                 (HTTP 403)         VAmPI pool
```

The NoName engine continuously updates the data groups via the F5 management
API as it identifies malicious IPs, query strings, cookies, and headers. The
iRule checks each inbound request against these lists in real time — no
additional round-trip to the engine is required on the data path.

---

## Data groups

Four internal data groups hold the block lists. They start empty; the NoName
engine populates them automatically once prevention rules are configured in
the portal.

| Data Group | Type | Blocks on |
|---|---|---|
| `noname_prevention_ip` | address | Source IP of the client |
| `noname_prevention_qs` | string | Query string parameters |
| `noname_prevention_cookie` | string | Cookie values |
| `noname_prevention_header` | string | HTTP header values |

---

## Installation

### Step 1 — Download the integration package and configure F5 credentials (NoName portal — manual)

1. Log into the NoName portal at `https://michaelc-lab.nonamesec.com`
2. Go to **Settings → Integrations → Prevention**
3. Select the **F5** tile and follow the wizard
4. When prompted for F5 connection details, enter:
   - **Management IP:** `10.0.7.20` (use the private IP — the engine is on the same VPC)
   - **Username / Password:** F5 admin credentials (Manager role or higher on the Common partition)
5. Download the ZIP — it contains `Noname-Prevention.tcl`

> **Why `10.0.7.20` and not the public EIP?** The engine runs on the k3s node
> inside the VPC. Using the private management IP keeps traffic off the internet
> and avoids dependency on your EIP staying the same.

### Step 2 — Create data groups (F5 tmsh or TMUI)

Create all four data groups as **internal** (not external file-based). They
must be empty at creation — the engine writes to them at runtime.

**Via tmsh:**
```bash
ssh -i ~/.ssh/mcropsey-key.pem admin@$F5_MGMT_IP

create ltm data-group internal noname_prevention_ip     { type ip }
create ltm data-group internal noname_prevention_qs     { type string }
create ltm data-group internal noname_prevention_cookie { type string }
create ltm data-group internal noname_prevention_header { type string }
save sys config
```

**Via TMUI:**
1. **Local Traffic → iRules → Data Group List → Create**
2. Repeat for each of the four data groups above, setting Name and Type as shown

### Step 3 — Upload iRule (TMUI — manual)

The iRule TCL file contains special characters that make command-line upload
unreliable. Use the browser:

1. Go to `https://<F5_MGMT_IP>`
2. **Local Traffic → iRules → iRule List → Create**
3. Set **Name** to `Noname-Prevention`
4. Paste the full contents of `Noname-Prevention.tcl` into **Definition**
5. Click **Finished**

### Step 4 — Attach iRule to virtual server

Attach `Noname-Prevention` to `vampi-vs` alongside the existing HSL iRule.
Both must be present — HSL sends traffic to the engine, Prevention enforces
the engine's decisions.

**Via tmsh:**
```bash
modify ltm virtual vampi-vs rules {
    /Common/noname-hsl-https-logger
    /Common/Noname-Prevention
}
save sys config
```

**Via TMUI:**
1. **Local Traffic → Virtual Servers → vampi-vs → Resources tab**
2. Next to **iRules**, click **Manage**
3. Move **Noname-Prevention** to **Enabled** (keep `noname-hsl-https-logger` enabled too)
4. Click **Finished**

> **Order matters.** The HSL iRule (`noname-hsl-https-logger`) should be listed
> first so traffic is captured before the prevention iRule can drop it. F5
> executes iRules in the order they appear on the VS.

---

## Verification

### Data groups exist

```bash
tmsh list ltm data-group internal | grep noname_prevention
```

Should list all four.

### iRule attached

```bash
tmsh list ltm virtual vampi-vs rules
```

Should show both `noname-hsl-https-logger` and `Noname-Prevention`.

### Prevention iRule is executing

```bash
tmsh show ltm rule Noname-Prevention
```

After sending traffic through the VIP, **Executions Total** should increment
with zero Failures or Aborts.

### Test a block (once portal has a prevention rule)

Create a prevention rule in the NoName portal targeting a known IP or query
string, then send a matching request:

```bash
# Example: test an IP block
curl -v http://$F5_VIP_IP/users/v1
# Should receive HTTP 403 if your source IP matches a block rule
```

---

## Troubleshooting

Work through these three stages in order. Each one tells you where to stop.

### Stage 1 — Did the entry make it into the data group?

Check the data groups first. If they are empty, the iRule is irrelevant — the
engine is not writing to them.

```bash
source lab-outputs.env
TOKEN=$(curl -sk -X POST "https://${F5_MGMT_IP}/mgmt/shared/authn/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<password>","loginProviderName":"tmos"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token']['token'])")

curl -sk -H "X-F5-Auth-Token: $TOKEN" \
  "https://${F5_MGMT_IP}/mgmt/tm/ltm/data-group/internal/noname_prevention_ip" \
  | python3 -m json.tool
```

**Empty data groups — common causes and fixes:**

| Cause | How to confirm | Fix |
|---|---|---|
| **k3s → F5 mgmt port 443 blocked** (most common) | SSH to k3s node: `curl -sk -o /dev/null -w '%{http_code}' https://10.0.7.20/mgmt/tm/...` — returns `000` | Add `10.0.8.0/24` to `mcropsey-f5-sg` inbound rule for TCP 443 (see prerequisite block at top of this doc) |
| F5 credentials not set in portal | Engine logs show `401` or connection errors | Go to **Settings → Integrations → Prevention → F5** and add admin credentials with management IP `10.0.7.20` |
| Wrong management IP in portal | Engine logs show `000` or timeout | Use private IP `10.0.7.20`, not the public EIP |
| Data groups in wrong partition | PUT returns 404 | Data groups must be in `/Common` — delete and recreate if needed |
| Name or type mismatch | Data group list doesn't match exactly | Names are case-sensitive; `noname_prevention_ip` must be type `address`, others type `string` |

**Quick connectivity test from the k3s node:**
```bash
ssh -i ~/.ssh/mcropsey-key.pem ec2-user@$K3S_PUBLIC_IP \
  "curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.7.20/mgmt/tm/ltm/data-group/internal/noname_prevention_ip"
# 401 = reachable (correct — needs auth)
# 000 = security group blocking — add the 10.0.8.0/24 rule
```

**Manually inject a test entry** to confirm the iRule works independently of
the engine:
```bash
tmsh modify ltm data-group internal noname_prevention_ip \
  { records add { 1.2.3.4/32 { } } }
# Then send a request from 1.2.3.4 and confirm 403
# Clean up when done:
tmsh modify ltm data-group internal noname_prevention_ip { records none }
```

### Stage 2 — Is the iRule actually running on that traffic?

Entry is in the data group but traffic still gets through.

```bash
# Check execution count — should increment as traffic hits the VIP
tmsh show ltm rule Noname-Prevention
```

If executions are zero:
- Confirm the iRule is attached: `tmsh list ltm virtual vampi-vs rules`
- Confirm `vampi-vs` has an HTTP profile: `tmsh list ltm virtual vampi-vs profiles`
  (HTTP_REQUEST never fires on a FastL4 VS)

### Stage 3 — Is the identifier what F5 sees?

Entry is in the data group, iRule is executing, but the specific request still
passes through.

- **Check the actual client IP** the F5 sees: add a `log local0. [IP::client_addr]`
  line to the iRule temporarily and tail `/var/log/ltm`. If anything sits in
  front of the F5 (CDN, proxy), F5 sees the proxy IP, not the attacker's.
- **Check expiry**: the engine pushes and removes entries on its own schedule.
  The entry you saw in the portal may have already been removed by the time you
  tested.

### iRule Failures or Aborts in stats

Check LTM logs:
```bash
tail -50 /var/log/ltm | grep -i noname
```

Common cause: a data group was renamed or deleted. Re-create it empty and the
iRule will resume.

### Traffic blocked unexpectedly

Check which data group is matching:
1. Temporarily enable debug logging in the iRule (set `nn_debug_mode true` if
   the iRule supports it)
2. Review `/var/log/ltm` for entries from `Noname-Prevention`
3. Check data group contents in the portal or via:
   ```bash
   tmsh list ltm data-group internal noname_prevention_ip
   tmsh list ltm data-group internal noname_prevention_qs
   ```

---

## Uninstalling

```bash
# 1. Remove Noname-Prevention from vampi-vs (keep HSL iRule)
modify ltm virtual vampi-vs rules { /Common/noname-hsl-https-logger }
save sys config

# 2. Delete iRule and data groups (optional)
delete ltm rule Noname-Prevention
delete ltm data-group internal noname_prevention_ip
delete ltm data-group internal noname_prevention_qs
delete ltm data-group internal noname_prevention_cookie
delete ltm data-group internal noname_prevention_header
save sys config

# 3. Delete the prevention integration profile in the NoName portal
```
