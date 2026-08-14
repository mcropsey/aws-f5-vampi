# F5 BIG-IP Prevention — NoName Integration

> **Prerequisite order:**
> 1. `01-deploy-aws.sh` → `02-configure-f5.sh` → `03-verify.sh` (VIP working)
> 2. NoName remote engine deployed and connected (`docs/noname-engine.md`)
> 3. F5 HSL source integration complete (`docs/f5-hsl-integration.md`)
> 4. Then this document

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

### Step 1 — Download the integration package (NoName portal — manual)

1. Log into the NoName portal at `https://michaelc-lab.nonamesec.com`
2. Go to **Settings → Integrations → Prevention**
3. Select the **F5** tile and follow the wizard
4. Download the ZIP — it contains `Noname-Prevention.tcl`

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

### Data groups not being populated

The NoName engine writes to data groups via the F5 management API. Confirm:
- The engine is connected in the portal (green status)
- The prevention integration profile is configured and active in the portal
- The F5 management IP (`$F5_MGMT_IP`) is reachable from the k3s node:
  ```bash
  ssh -i ~/.ssh/mcropsey-key.pem ec2-user@3.136.119.100
  curl -sk https://<F5_MGMT_IP>/mgmt/tm/ltm/data-group/internal/noname_prevention_ip \
    -u admin:Forza5-GP100 | python3 -m json.tool
  ```

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
