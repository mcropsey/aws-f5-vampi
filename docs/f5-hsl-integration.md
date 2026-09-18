# F5 BIG-IP HSL — NoName Integration

> **Prerequisite order:**
> 1. `01-deploy-aws.sh` → `02-configure-f5.sh` → `03-verify.sh` (VIP working)
> 2. NoName remote engine deployed and **registered** in the portal (`docs/noname-engine.md`)
> 3. Then this document
>
> **Rewritten 2026-09-15 against a working deployment.** The earlier version of
> this doc described an 8-step chain with a TLS-terminating virtual server, a
> `nats-jetstream` CPU patch and a manual TMUI paste. None of those are needed.
> What actually works is **three objects**, and all of the F5 work is REST.

This integration lets the NoName / Akamai API Security engine capture API
traffic from the F5 BIG-IP LTM using High-Speed Logging. The iRule fires on
every HTTP request/response through `vampi-vs` and forwards a base64 payload
asynchronously to the engine.

---

## What you actually create

| # | Where | Object | How |
|---|---|---|---|
| 1 | k3s | catch-all Ingress `noname-hsl-engine-ingress`, `/engine` → `router:8080` | `kubectl` |
| 2 | F5 | pool `noname-security-hsl-https` → `10.0.8.100:80`, `tcp` monitor | iControl REST |
| 3 | F5 | iRule `noname-hsl-https-logger`, attached to `vampi-vs` | iControl REST |

### Why this is shorter than it looks like it should be

**`HSL::open -proto TCP` emits plaintext.** It is a raw TCP log stream — there
is no TLS on it and no way to add one. The iRule hand-builds an HTTP request
(`POST /engine?message-format=base64 HTTP/1.1`) and writes it onto that socket.

So pointing the HSL pool at a `:443` backend can never work directly, which is
the only reason the old doc needed a middle virtual server with a `serverssl`
profile: something had to wrap the plaintext in TLS. Point the HSL pool at the
ingress's **port 80** instead and both the virtual server and the second pool
disappear.

**Trade-off:** telemetry now crosses the VPC between `10.0.5.0/24` and
`10.0.8.0/24` as plaintext HTTP. Acceptable for a lab on a private VPC. To
encrypt it, re-introduce the middle VS (see *Optional: putting TLS back*).

---

## Traffic flow

```
Client
  │
  ▼
vampi-vs (10.0.5.10:80)
  │  iRule fires on CLIENT_ACCEPTED / HTTP_REQUEST / HTTP_RESPONSE[_DATA]
  │
  ▼ HSL::open -proto TCP -pool $nn_pool      (plaintext, fire-and-forget)
noname-security-hsl-https pool → 10.0.8.100:80
  │
  ▼ POST /engine?message-format=base64   Host: 10.0.8.100
k3s NGINX ingress (hostNetwork, port 80)
  │  catch-all ingress: path /engine → router:8080
  │
  ▼
router service :8080
  │
  ▼ NATS
engine pod → michaelc-lab.nonamesec.com (outbound)
```

**Key addresses** (live values are always in `lab-outputs.env`):

| Object | Address | Notes |
|---|---|---|
| F5 VIP (traffic path) | `10.0.5.10:80` | `vampi-vs`, where the iRule is attached |
| NoName sensor IP | `10.0.8.100:80` | Secondary IP on the k3s node — see caveat below |
| k3s node primary IP | `10.0.8.245` | `K3S_PRIVATE_IP` |
| k3s node public IP | `77.112.67.187` | `K3S_PUBLIC_IP` |

> ⚠ **`10.0.8.100` is not reserved by CloudFormation.** `mcropsey-lab.yaml` has
> no `NetworkInterfaces` block and never mentions this address; it was added to
> `eth0` by hand, as a `/32`, plus a SNAT rule. `01-deploy-aws.sh` writes
> `NONAME_SENSOR_IP="10.0.8.100"` into `lab-outputs.env` regardless, so on a
> fresh deploy that variable names an address that exists nowhere. See
> **"Sensor IP must not be primary"** in `docs/noname-engine.md` for the exact
> commands, and do not skip the `/32` — a `/24` silently blackholes all pod
> egress.

---

## Step 1 — Configure the integration profile (NoName portal — manual)

1. Log into the NoName portal at `https://michaelc-lab.nonamesec.com`
2. **Settings → Integrations → Traffic Sources → Add Integration**
3. Select the **F5** tile
4. Enter a name, select **HSL**, and select the remote engine
5. Click **Create**
6. **Download the ZIP** — extract it to get `send-to-noname.tcl`

The iRule arrives pre-configured with your `source_key` and `engine_hostname`.
Check that `engine_hostname` matches your sensor IP:

```bash
grep -n 'engine_hostname\|nn_pool\|engine_url' ~/Downloads/send-to-noname.tcl
```

Expected:
```tcl
set static::nn_..._engine_hostname "10.0.8.100"
set static::nn_..._engine_url "/engine?message-format=base64"
set nn_pool noname-security-hsl-https
```

The `engine_hostname` only becomes the `Host:` header — routing is decided by
the **pool** (Step 3). The pool name in the iRule is what the F5 object must be
called; don't rename one without the other.

---

## Step 2 — k3s: catch-all ingress for `/engine`

**This step is load-bearing.** Without it the request is a 404 and the
telemetry is dropped — and nothing on the F5 will tell you, because HSL is
fire-and-forget. Measured on this deployment: `/engine` returned **404 before**
the ingress and **200 after**, with identical, healthy F5 iRule statistics in
both cases.

The chart's own ingress only matches `engine.michaelc-lab.local`, but the iRule
sends `Host: 10.0.8.100`. `networking.k8s.io/v1` rejects a raw IP in
`spec.rules[].host`, so a no-host catch-all is the fix rather than a workaround.

```bash
ssh -i ~/.ssh/mcropsey-key.pem ec2-user@77.112.67.187
export KUBECONFIG=$HOME/.kube/config    # or /etc/rancher/k3s/k3s.yaml

kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: noname-hsl-engine-ingress
  namespace: akamai-api-security
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "30"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /engine
        pathType: Prefix
        backend:
          service:
            name: router
            port:
              number: 8080
EOF
```

Verify — and verify with the *exact* request the iRule sends, not a bare GET:

```bash
kubectl get ingress -n akamai-api-security
# noname-hsl-engine-ingress must show HOSTS: *

curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST 'http://10.0.8.100/engine?message-format=base64' \
  -H 'Host: 10.0.8.100' --data 'probe'
# want: 200   (404 = the catch-all ingress is missing or not matching)
```

> The k3s security group already allows all protocols from `10.0.6.0/24` (the
> F5 internal self IP), so no SG change is needed for port 80. Do not open it
> more widely.

---

## Step 3 — F5: create the HSL pool

One pool, straight at the ingress. `monitor tcp` rather than `http`, because
`/engine` is POST-only and an HTTP monitor's GET would mark it down.

```bash
cd ~/Downloads/aws-f5-vampi
set -a; source .f5-admin-password; set +a

./f5-api.sh POST /mgmt/tm/ltm/pool '{
  "name": "noname-security-hsl-https",
  "monitor": "tcp",
  "members": [{"name": "10.0.8.100:80", "address": "10.0.8.100"}]
}'
```

Confirm by re-reading it — see the `f5-api.sh` caveat in *Gotchas*:

```bash
./f5-api.sh GET '/mgmt/tm/ltm/pool/~Common~noname-security-hsl-https/members' \
  | jq -r '.items[] | "\(.name) \(.state) \(.session)"'
# want: 10.0.8.100:80 up monitor-enabled
```

---

## Step 4 — F5: upload the iRule (REST, no TMUI needed)

The old doc sent you to the browser here. That isn't necessary — the 384-line
iRule with all seven `proc` definitions uploads cleanly through
`/mgmt/tm/ltm/rule` using the `apiAnonymous` field.

**One catch.** The vendor file contains non-ASCII characters — `²`, in
`O(n²)`-style comments. BIG-IP's TCL parser rejects the whole script with a
message that points at the wrong place entirely:

```
can't parse TCL script beginning with ... when HTTP_REQUEST {
```

That error names an event handler hundreds of lines away from the real problem,
so it reads like a `proc`/brace issue. It isn't. Strip the non-ASCII:

```bash
python3 - <<'PY'
import json
src = open('/Users/mcropsey/Downloads/send-to-noname.tcl', encoding='utf-8').read()
src = src.replace('²', '^2')                       # O(n²) -> O(n^2)
src = src.encode('ascii', 'replace').decode('ascii')    # catch any others
open('/tmp/irule.json', 'w').write(json.dumps(
    {"name": "noname-hsl-https-logger", "apiAnonymous": src}))
print(len(src), 'bytes,', 'non-ascii:', any(ord(c) > 127 for c in src))
PY

./f5-api.sh POST /mgmt/tm/ltm/rule "$(cat /tmp/irule.json)"
```

Verify by size, since the create response is not trustworthy on its own:

```bash
./f5-api.sh GET /mgmt/tm/ltm/rule/~Common~noname-hsl-https-logger \
  | jq -r '.apiAnonymous | length'
# want: ~16700
```

This edits only comments. If NoName support asks you not to modify the file,
that concern is about the `source_key` and the payload logic, not about `²`.

---

## Step 5 — F5: attach the iRule to `vampi-vs`

`PATCH` replaces the whole `rules` array, so read it first and include anything
already there.

```bash
./f5-api.sh GET /mgmt/tm/ltm/virtual/~Common~vampi-vs | jq '.rules'

./f5-api.sh PATCH /mgmt/tm/ltm/virtual/~Common~vampi-vs \
  '{"rules":["/Common/noname-hsl-https-logger"]}'

./f5-api.sh POST /mgmt/tm/sys/config '{"command":"save"}'
```

---

## Verification

Generate traffic first — the engine has nothing to report until something flows:

```bash
source lab-outputs.env
for p in / /users/v1 /createdb /books/v1; do
  curl -s -o /dev/null -w "$p %{http_code}\n" "http://$F5_VIP_IP$p"
done
```

### 1. F5 — the iRule is firing

```bash
./f5-api.sh GET /mgmt/tm/ltm/rule/~Common~noname-hsl-https-logger/stats \
  | jq -r '.entries[].nestedStats.entries
           | "\(.eventType.description) exec=\(.totalExecutions.value) fail=\(.failures.value) err=\(.aborts.value)"'
```

Expected shape after four requests (counters are cumulative — what matters is
that they track your request count and that `fail`/`err` stay at 0):

```
CLIENT_ACCEPTED     exec=4  fail=0  err=0
HTTP_REQUEST        exec=4  fail=0  err=0
HTTP_REQUEST_DATA   exec=0  fail=0  err=0
HTTP_RESPONSE       exec=4  fail=0  err=0
HTTP_RESPONSE_DATA  exec=4  fail=0  err=0
RULE_INIT           exec=2  fail=0  err=0
```

`HTTP_REQUEST_DATA exec=0` is normal — that event only fires when a request has
a body to collect, and plain `GET`s have none. `RULE_INIT` sits at 2 because it
runs once per TMM, not once per request.

**Do not stop here.** These counters stay clean even when every payload is
being 404'd or blackholed — HSL never reports back. This proves the iRule runs,
nothing more.

### 2. F5 — pool is up

```bash
./f5-api.sh GET '/mgmt/tm/ltm/pool/~Common~noname-security-hsl-https/members' \
  | jq -r '.items[] | "\(.name) \(.state)"'
```

### 3. k3s — the POSTs arrived and were accepted

This is the first check that can actually fail. The source address is the
proof: `10.0.6.10` is the F5's internal self IP.

```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=100 \
  | grep '/engine'
```

Want:
```
10.0.6.10 ... "POST /engine?message-format=base64 HTTP/1.1" 200 1
```

A `404` means Step 2 is missing. No lines at all means the F5 never reached the
node — check the pool, and check that `10.0.8.100` is actually on `eth0`
(`ip -4 addr show dev eth0`).

### 4. k3s — the engine processed them

```bash
kubectl logs -n akamai-api-security -l app=engine --tail=200 \
  | grep -o '"total_recorded_apis":[^,]*\|"packets_received_from_nats":[^,]*\|"Schema_packets_processed":[^,]*'
```

The engine emits this block periodically, so you get one line per cycle and the
values climb. First cycle after the four requests above, then a later one:

```
"packets_received_from_nats": 6,   "total_recorded_apis": 4,   "Schema_packets_processed": 4
"packets_received_from_nats": 41,  "total_recorded_apis": 16,  "Schema_packets_processed": 39
```

`total_recorded_apis` climbing to match the distinct endpoints you have driven
through the VIP is the end-to-end proof. A single cycle showing
`"Schema_packets_processed": 0` right after first traffic is not a failure —
it means that cycle's packets had not been schema-processed yet; check the next
one.

> The old doc told you to grep the **router** logs for
> `total_messages_pushed_to_ingest` / `pushed_to_nats`. Those keys do not appear
> in v3.71.0's router output — the grep comes back empty on a fully working
> path. Use the engine telemetry above instead.

### 5. NoName portal

The integration connector flips from **pending** to **online** once the engine
processes traffic and heartbeats to the management plane — 1–2 minutes after
first traffic. The recorded endpoints then appear under **APIs**.

---

## Gotchas

**`f5-api.sh` exits 0 on a 404.** BIG-IP answers a missing object with HTTP 404
*and a JSON body*, and the script reports that faithfully as success:

```json
{"code": 404, "message": "01020036:3: The requested Pool (...) was not found."}
```

So `./f5-api.sh GET ... >/dev/null 2>&1 && echo exists` always prints `exists`.
Parse the body — `jq -e 'has("code") | not'` — never the exit code.

**BIG-IP returns advisory messages shaped like errors.** Virtual-server creates
emit a `traffic-group-local-only` warning that looks fatal. Always confirm a
create by re-`GET`ing the object, not by reading the create response.

**HSL cannot do TLS, and cannot report failure.** Both consequences matter: the
backend must be plaintext, and the F5 side of this integration is blind. Every
real diagnosis happens on the k3s side.

**A clean `curl` is not the same request.** `GET /engine` and
`POST /engine?message-format=base64` can behave differently through an ingress.
Probe with the request the iRule actually sends.

---

## Optional: putting TLS back

If this ever needs to leave a trusted network, the plaintext hop is the thing to
fix. Keep Steps 1, 2, 4, 5 and replace Step 3 with the original three-object
chain:

```bash
# backend pool → the ingress on 443
./f5-api.sh POST /mgmt/tm/ltm/pool '{
  "name": "noname-security-engine-https-pool", "monitor": "tcp",
  "members": [{"name": "10.0.8.100:443", "address": "10.0.8.100"}]}'

# middle VS: plaintext in from HSL, TLS out to the ingress.
# 10.0.5.20 is in the external subnet but is NOT the self IP (10.0.5.10),
# so BIG-IP accepts it as a virtual-server destination.
./f5-api.sh POST /mgmt/tm/ltm/virtual '{
  "name": "noname-security-engine-https-vs",
  "destination": "10.0.5.20:8443", "ipProtocol": "tcp",
  "pool": "noname-security-engine-https-pool",
  "profiles": [{"name":"http"},{"name":"serverssl","context":"serverside"}],
  "sourceAddressTranslation": {"type":"automap"}}'

# HSL pool now points at the middle VS instead of the node
./f5-api.sh POST /mgmt/tm/ltm/pool '{
  "name": "noname-security-hsl-https", "monitor": "tcp_half_open",
  "members": [{"name": "10.0.5.20:8443", "address": "10.0.5.20"}]}'
```

The k3s ingress must then terminate TLS on 443 (the chart's nginx runs with
`hostNetwork: true`, so it already holds both 80 and 443 on the node).

---

## Removed from this doc

**The `nats-jetstream` CPU patch** (old Step 3). It was a symptom fix for
`Pending` pods, superseded by one supported value:

```yaml
global:
  engine:
    engineSizing: "micro"
```

`medium` (the chart default) requests 17300m CPU and cannot fit on a 16 vCPU
`m5.4xlarge`; `micro` totals 8300m. See `docs/noname-engine.md`. The
`nats_jetstream:` values key the old doc suggested for persistence **does not
exist** anywhere in chart v3.71.0 — setting it does nothing.

**`global.engine.hostNetwork: "true"`** is *not* required for HSL. It exists to
make `light-engine` bind UDP 4789 on the node for the **clone-pool / VXLAN**
integration, which is a *different and mutually exclusive* integration from this
one. Both target `10.0.8.100`, on different ports, which is an easy way to
confuse the two docs:

| | Port | Needs `hostNetwork` | Doc |
|---|---|---|---|
| HSL (this doc) | TCP 80 | no | `f5-hsl-integration.md` |
| Clone pool / VXLAN | UDP 4789 | **yes** | `noname-engine.md` Phase 3 |

Pick one. It is currently left enabled on this stack — harmless, and it keeps
the clone-pool option available.

**The manual TMUI iRule paste** (old Step 7) — see Step 4.

**The pre-4.0.0 `HSL::open` workaround.** The current `send-to-noname.tcl`
already uses the `set nn_pool` variable form, so there is nothing to change.

---

## Updating the iRule

Download the new ZIP from the portal, then re-run the Step 4 upload as a `PATCH`
(same non-ASCII strip — the vendor file still has the `²`):

```bash
./f5-api.sh PATCH /mgmt/tm/ltm/rule/~Common~noname-hsl-https-logger \
  "$(cat /tmp/irule.json)"
./f5-api.sh POST /mgmt/tm/sys/config '{"command":"save"}'
```

No pool, ingress or virtual-server changes are needed for an iRule update.

---

## Uninstalling

```bash
cd ~/Downloads/aws-f5-vampi
set -a; source .f5-admin-password; set +a

./f5-api.sh PATCH /mgmt/tm/ltm/virtual/~Common~vampi-vs '{"rules":[]}'
./f5-api.sh DELETE /mgmt/tm/ltm/rule/~Common~noname-hsl-https-logger
./f5-api.sh DELETE /mgmt/tm/ltm/pool/~Common~noname-security-hsl-https
./f5-api.sh POST   /mgmt/tm/sys/config '{"command":"save"}'

# k3s
kubectl delete ingress noname-hsl-engine-ingress -n akamai-api-security

# Portal: Settings → Integrations → Traffic Sources → (your integration) → Delete
```

Detach the iRule **before** deleting it — BIG-IP refuses to delete a rule that
is still referenced by a virtual server.
