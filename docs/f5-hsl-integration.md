# F5 BIG-IP HSL — NoName Integration (HTTPS to the remote engine)

> **Prerequisite order:**
> 1. `01-deploy-aws.sh` → `02-configure-f5.sh` → `03-verify.sh` (VIP working)
> 2. NoName remote engine deployed and **registered** in the portal (`docs/noname-engine.md`)
> 3. Then this document
>
> **Rewritten 2026-09-18 against the live deployment.** The 2026-09-15 revision
> of this doc described a two-hop **plaintext** chain and demoted TLS to an
> optional appendix. That is not what is running. The live BIG-IP reaches the
> remote engine over **HTTPS on port 443**, via a TLS-terminating middle virtual
> server. The five objects below are read back from the running device.

This integration lets the NoName / Akamai API Security engine capture API
traffic from the F5 BIG-IP LTM using High-Speed Logging. The iRule fires on
every HTTP request/response through `vampi-vs` and forwards a base64 payload
asynchronously to the engine.

---

## What you actually create

| # | Where | Object | Kind | How |
|---|---|---|---|---|
| 1 | k3s | Ingress `noname-hsl-engine-ingress`, catch-all `/engine` → `router:8080` | Ingress | `kubectl` |
| 2 | F5 | `noname-security-engine-https-pool` → `10.0.8.100:443` | pool | iControl REST |
| 3 | F5 | `noname-https-monitor` | HTTPS monitor | iControl REST |
| 4 | F5 | `noname-serverssl` | server-ssl profile | iControl REST |
| 5 | F5 | `noname-security-engine-https-vs` @ `10.0.6.100:80` | virtual server | iControl REST |
| 6 | F5 | `noname-security-hsl-https` → `10.0.6.100:80` | pool (HSL target) | iControl REST |
| 7 | F5 | `noname-hsl-https-logger`, attached to `vampi-vs` | iRule | iControl REST |

### Why the middle virtual server is required

**`HSL::open -proto TCP` emits plaintext and cannot be given TLS.** It is a raw
TCP log stream. The iRule hand-builds an HTTP request
(`POST /engine?message-format=base64 HTTP/1.1`) and writes it onto that socket.
There is no `-proto SSL`, no serverssl hook, no way to attach a profile to an
HSL publisher.

So the HSL pool can never point at a `:443` backend directly. **Something on the
BIG-IP has to wrap the plaintext in TLS**, and that something is a virtual
server with a `serverssl` profile on the server side:

```
HSL (plaintext, unavoidable)  →  middle VS  →  TLS  →  engine :443
        never leaves the BIG-IP              crosses the VPC encrypted
```

The plaintext hop still exists, but it is now **internal to the BIG-IP** —
TMM to TMM, never on the wire. Everything that crosses the VPC between the F5
and the k3s node is TLS.

---

## Traffic flow

```
Client
  │
  ▼
vampi-vs (10.0.5.10:80)   profiles: http, tcp   pool: vampi-pool
  │  iRule noname-hsl-https-logger fires on
  │  CLIENT_ACCEPTED / HTTP_REQUEST / HTTP_RESPONSE[_DATA]
  │
  ▼ HSL::open -proto TCP -pool noname-security-hsl-https
  │  (plaintext, fire-and-forget, never leaves the BIG-IP)
pool noname-security-hsl-https → 10.0.6.100:80        monitor tcp_half_open
  │
  ▼ POST /engine?message-format=base64   Host: 10.0.8.100
noname-security-engine-https-vs (10.0.6.100:80)
  │  profiles: http, tcp, noname-serverssl (serverside)   SNAT: automap
  │  ── TLS starts here ──
  ▼
pool noname-security-engine-https-pool → 10.0.8.100:443   monitor noname-https-monitor
  │
  ▼ HTTPS, source 10.0.6.10 (automap), SNI michaelc-lab.nonamesec.com
k3s NGINX ingress (hostNetwork, terminates TLS on 443, default self-signed cert)
  │  catch-all ingress: path /engine → router:8080
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
| F5 external self IP | `10.0.5.10/24` | `self-ext`, VLAN `external` |
| F5 internal self IP | `10.0.6.10/24` | `self-int`, VLAN `internal` — the source IP k3s sees |
| **F5 middle VS** | **`10.0.6.100:80`** | TLS wrapper — F5-internal only, see caveat |
| NoName sensor IP | `10.0.8.100:443` | Secondary IP on the k3s node — see caveat |
| k3s node primary IP | `10.0.8.245` | `K3S_PRIVATE_IP` |
| k3s node public IP | `77.112.67.187` | `K3S_PUBLIC_IP` |

> ⚠ **`10.0.6.100` and `10.0.8.100` are one character apart and are different
> things.** `10.0.6.100` is the BIG-IP's middle virtual server. `10.0.8.100` is
> the engine sensor address on the k3s node. Transposing them produces a pool
> that monitors `up` and telemetry that silently goes nowhere.

> ⚠ **`10.0.6.100` does not exist in AWS — and does not need to.** Verified:
> `aws ec2 describe-network-interfaces --filters Name=private-ip-address,Values=10.0.6.100`
> returns `[]`, and the F5's internal ENI carries only `10.0.6.10`. It works
> because the HSL traffic *originates on the BIG-IP* and terminates on a virtual
> server *on the same BIG-IP* — the packet is handled internally and never
> reaches the AWS fabric, so no secondary IP, ARP entry or route is required.
> Do not "fix" this by assigning it to the ENI.

> ⚠ **`10.0.8.100` is not reserved by CloudFormation.** `mcropsey-lab.yaml` has
> no `NetworkInterfaces` block and never mentions this address; it was added to
> `eth0` by hand, as a `/32`, plus a SNAT rule. (It *is* currently a real
> secondary IP on the k3s ENI, alongside `10.0.8.245`.) `01-deploy-aws.sh`
> writes `NONAME_SENSOR_IP="10.0.8.100"` into `lab-outputs.env` regardless, so
> on a fresh deploy that variable names an address that exists nowhere. See
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

Expected (matches the live iRule on this device):
```tcl
set static::nn_1789519311072_engine_hostname "10.0.8.100"
set static::nn_1789519311072_engine_url "/engine?message-format=base64"
set nn_pool noname-security-hsl-https
```

Two things to understand about these values, because they are what makes the
TLS chain work without editing the vendor file:

- **`engine_hostname` only becomes the `Host:` header.** It stays `10.0.8.100`
  even though the HSL pool sends to `10.0.6.100`. Routing is decided entirely by
  the **pool**, and the `Host:` header has to name the *final* destination so the
  k3s ingress matches. Do not change it to `10.0.6.100`.
- **`nn_pool` is the F5 object name.** The pool must be called exactly
  `noname-security-hsl-https`; don't rename one without the other. The `-https`
  in that name refers to the integration, not to the protocol on that hop —
  that hop is plaintext by necessity (see *Why the middle virtual server is
  required*).

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

**No `tls:` block is needed.** The ingress-nginx controller runs with
`hostNetwork: true` and already holds both 80 and 443 on the node; on 443 it
serves its built-in self-signed default certificate. That is what the F5
connects to, and it is why `noname-serverssl` sets `peerCertMode: ignore`
(Step 4). Adding a `tls:` block with a real cert is a hardening option, not a
requirement.

Verify — and verify with the *exact* request the iRule sends, not a bare GET:

```bash
kubectl get ingress -n akamai-api-security
# noname-hsl-engine-ingress must show HOSTS: *

# plaintext probe (from the node itself)
curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST 'http://10.0.8.100/engine?message-format=base64' \
  -H 'Host: 10.0.8.100' --data 'probe'

# the probe that matches what the F5 actually sends — TLS on 443
curl -sk -o /dev/null -w '%{http_code}\n' \
  -X POST 'https://10.0.8.100/engine?message-format=base64' \
  -H 'Host: 10.0.8.100' --data 'probe'
# want: 200   (404 = the catch-all ingress is missing or not matching)
```

> The k3s security group already allows all protocols from `10.0.6.0/24` (the
> F5 internal self IP), so no SG change is needed for 443. Do not open it more
> widely.

---

## Step 3 — F5: backend pool to the engine on 443

This is the pool that actually talks to the engine over TLS.

```bash
cd ~/Downloads/aws-f5-vampi
set -a; source .f5-admin-password; set +a

./f5-api.sh POST /mgmt/tm/ltm/pool '{
  "name": "noname-security-engine-https-pool",
  "members": [{"name": "10.0.8.100:443", "address": "10.0.8.100"}]
}'
```

### The HTTPS monitor

A plain `tcp` monitor will mark this member up as soon as the TCP handshake
completes, which hides a broken TLS or ingress config. The live device uses a
purpose-built HTTPS monitor instead. Note the explicit `Host:` header — without
it nginx has no host to match and the probe is less meaningful — and `recv`
matching just `HTTP`, because `GET /` through the catch-all ingress legitimately
returns a 404 and any stricter `recv` would flap the pool.

```bash
./f5-api.sh POST /mgmt/tm/ltm/monitor/https '{
  "name": "noname-https-monitor",
  "defaultsFrom": "/Common/https",
  "send": "GET / HTTP/1.1\r\nHost: 10.0.8.100\r\nConnection: close\r\n\r\n",
  "recv": "HTTP",
  "interval": 5,
  "timeout": 16
}'

./f5-api.sh PATCH /mgmt/tm/ltm/pool/~Common~noname-security-engine-https-pool \
  '{"monitor": "/Common/noname-https-monitor"}'
```

Confirm — re-read it, don't trust the create response:

```bash
./f5-api.sh GET '/mgmt/tm/ltm/pool/~Common~noname-security-engine-https-pool/members' \
  | jq -r '.items[] | "\(.name) \(.state)"'
# want: 10.0.8.100:443 up
```

---

## Step 4 — F5: the server-ssl profile

The stock `serverssl` profile will not do here: it would try to validate the
ingress's self-signed default certificate. This profile is a child of
`serverssl` with validation disabled and SNI set to the portal hostname.

```bash
./f5-api.sh POST /mgmt/tm/ltm/profile/server-ssl '{
  "name": "noname-serverssl",
  "defaultsFrom": "/Common/serverssl",
  "ciphers": "DEFAULT",
  "serverName": "michaelc-lab.nonamesec.com",
  "peerCertMode": "ignore",
  "sniDefault": "false",
  "secureRenegotiation": "require-strict"
}'
```

| Setting | Live value | Why |
|---|---|---|
| `defaultsFrom` | `/Common/serverssl` | inherit stock defaults |
| `cert` / `key` | `none` | no client certificate; the engine does not ask for one |
| `peerCertMode` | `ignore` | ingress-nginx presents its self-signed default cert |
| `serverName` | `michaelc-lab.nonamesec.com` | SNI sent on the handshake |
| `sniDefault` | `false` | not the fallback profile for unmatched SNI |
| `secureRenegotiation` | `require-strict` | RFC 5746 strict — stock default, kept |

> `peerCertMode: ignore` is the deliberate trade-off that lets this work against
> the ingress's default certificate. The hop is encrypted but not authenticated.
> To close that, give the ingress a real cert via a `tls:` block, then set
> `peerCertMode: require` and attach the issuing CA as `caFile`.

---

## Step 5 — F5: the middle virtual server

Plaintext in from HSL on port 80, TLS out to the engine. This is the object the
previous revision of this doc claimed was unnecessary.

```bash
./f5-api.sh POST /mgmt/tm/ltm/virtual '{
  "name": "noname-security-engine-https-vs",
  "destination": "10.0.6.100:80",
  "mask": "255.255.255.255",
  "ipProtocol": "tcp",
  "pool": "noname-security-engine-https-pool",
  "profiles": [
    {"name": "tcp", "context": "all"},
    {"name": "http", "context": "all"},
    {"name": "noname-serverssl", "context": "serverside"}
  ],
  "sourceAddressTranslation": {"type": "automap"}
}'
```

Notes on the live values, each of which matters:

- **`10.0.6.100` is on the internal subnet**, not the external one. The F5's
  internal self IP is `10.0.6.10/24`, so `.100` is a free host address in a
  subnet the BIG-IP already owns. (An earlier draft of this doc proposed
  `10.0.5.20:8443` on the external subnet — that is *not* what runs here.)
- **`mask: 255.255.255.255`** — a host virtual, not a network virtual.
- **The `http` profile is required.** The serverside TLS re-encrypt needs the
  connection parsed as HTTP for the request the iRule hand-built to be proxied
  correctly.
- **`automap`** is why the k3s ingress logs show source `10.0.6.10` rather than
  a client address.
- **No VLAN restriction** (`vlans: null`). The traffic is BIG-IP-internal, so
  there is no VLAN to lock it to.

Confirm — virtual-server creates emit a `traffic-group-local-only` advisory that
looks like an error:

```bash
./f5-api.sh GET /mgmt/tm/ltm/virtual/~Common~noname-security-engine-https-vs \
  | jq '{destination, pool, sourceAddressTranslation: .sourceAddressTranslation.type}'
./f5-api.sh GET /mgmt/tm/ltm/virtual/~Common~noname-security-engine-https-vs/profiles \
  | jq -r '.items[] | "\(.name) \(.context)"'
# want: http all / noname-serverssl serverside / tcp all
```

---

## Step 6 — F5: the HSL pool, pointed at the middle VS

The pool the iRule names. Its member is the **middle virtual server**, not the
engine.

`tcp_half_open` rather than `tcp`: a full-open TCP monitor completes a handshake
against the virtual server and immediately resets it, which shows up as noise in
the VS connection stats. Half-open probes without establishing.

```bash
./f5-api.sh POST /mgmt/tm/ltm/pool '{
  "name": "noname-security-hsl-https",
  "monitor": "tcp_half_open",
  "members": [{"name": "10.0.6.100:80", "address": "10.0.6.100"}]
}'

./f5-api.sh GET '/mgmt/tm/ltm/pool/~Common~noname-security-hsl-https/members' \
  | jq -r '.items[] | "\(.name) \(.state) \(.session)"'
# want: 10.0.6.100:80 up monitor-enabled
```

---

## Step 7 — F5: upload the iRule (REST, no TMUI needed)

The 384-line iRule with all seven `proc` definitions uploads cleanly through
`/mgmt/tm/ltm/rule` using the `apiAnonymous` field. Nothing in the iRule changes
for the TLS chain — it still opens a plaintext HSL connection to
`noname-security-hsl-https`, and the middle VS does the rest.

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

A known-good copy of the live rule is checked in as
`noname-hsl-irule.backup-20260916-115633.tcl` (384 lines, byte-identical to what
is on the device as of 2026-09-18).

---

## Step 8 — F5: attach the iRule to `vampi-vs`

`PATCH` replaces the whole `rules` array, so read it first and include anything
already there.

```bash
./f5-api.sh GET /mgmt/tm/ltm/virtual/~Common~vampi-vs | jq '.rules'

./f5-api.sh PATCH /mgmt/tm/ltm/virtual/~Common~vampi-vs \
  '{"rules":["/Common/noname-hsl-https-logger"]}'

./f5-api.sh POST /mgmt/tm/sys/config '{"command":"save"}'
```

`vampi-vs` itself keeps only `http` and `tcp` profiles — the iRule does not
require anything else on the client-facing virtual server.

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

### 2. F5 — both hops are carrying traffic

This is the check that actually proves the TLS chain, and it is the one the
previous revision of this doc could not express. Both pools must show climbing
connection counts:

```bash
for p in noname-security-hsl-https noname-security-engine-https-pool; do
  echo "=== $p"
  ./f5-api.sh GET "/mgmt/tm/ltm/pool/~Common~$p/members/stats" \
    | jq -r '.entries[].nestedStats.entries
             | "\(.nodeName.description):\(.port.value) conns=\(.["serverside.totConns"].value) state=\(.["status.availabilityState"].description)"'
done
```

Observed on the live device:

```
=== noname-security-hsl-https
/Common/10.0.6.100:80  conns=551  state=available
=== noname-security-engine-https-pool
/Common/10.0.8.100:443 conns=508  state=available
```

Both counters climbing together is the proof that HSL reached the middle VS
**and** that the middle VS completed TLS to the engine. If the first climbs and
the second is flat, TLS is failing — check `noname-serverssl` and the ingress's
443 listener.

### 3. k3s — the POSTs arrived and were accepted

The source address is the proof: `10.0.6.10` is the F5's internal self IP,
via `automap` on the middle VS.

```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=100 \
  | grep '/engine'
```

Want (captured live):
```
10.0.6.10 - - [18/Sep/2026:17:55:14 +0000] "POST /engine?message-format=base64 HTTP/1.1" 200 1 ... [akamai-api-security-router-8080] 10.42.0.21:8080 1 0.000 200
```

A `404` means Step 2 is missing. No lines at all means the F5 never reached the
node — check both pools (check 2), and check that `10.0.8.100` is actually on
`eth0` (`ip -4 addr show dev eth0`).

An occasional `a client request body is buffered to a temporary file` warning
from nginx is normal — large response bodies produce large base64 payloads.

### 4. k3s — the engine processed them

```bash
kubectl logs -n akamai-api-security -l app=engine --tail=200 \
  | grep -o '"total_recorded_apis":[^,]*\|"packets_received_from_nats":[^,]*\|"Schema_packets_processed":[^,]*'
```

The engine emits this block periodically, so you get one line per cycle and the
values climb:

```
"packets_received_from_nats": 6,   "total_recorded_apis": 4,   "Schema_packets_processed": 4
"packets_received_from_nats": 41,  "total_recorded_apis": 16,  "Schema_packets_processed": 39
```

`total_recorded_apis` climbing to match the distinct endpoints you have driven
through the VIP is the end-to-end proof. A single cycle showing
`"Schema_packets_processed": 0` right after first traffic is not a failure —
it means that cycle's packets had not been schema-processed yet; check the next
one.

> An older doc told you to grep the **router** logs for
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

**HSL cannot do TLS, and cannot report failure.** The first half is why the
middle VS exists. The second half still bites: the F5 side of this integration
is blind, so a healthy iRule stat proves nothing about delivery. Use the
two-hop pool stats (check 2) and the k3s logs (check 3).

**The pool named `-https` is the plaintext hop.** `noname-security-hsl-https`
carries cleartext to `10.0.6.100:80`. The name describes the integration, not
that hop's protocol. This is the single most confusing thing about the
configuration, and renaming it means editing the vendor iRule's `nn_pool`.

**A clean `curl` is not the same request.** `GET /engine` and
`POST /engine?message-format=base64` can behave differently through an ingress,
and so can `http://` versus `https://`. Probe with the request the iRule
actually sends, on 443.

**Order of creation matters.** The middle VS references the profile and the
backend pool; the HSL pool references the middle VS's address. Build Steps 3 → 4
→ 5 → 6 in order, or the creates fail on missing references.

---

## Optional: dropping TLS (plaintext to the engine)

Only for a throwaway lab on a trusted private VPC, and only if you accept
telemetry — which contains full request and response bodies — crossing the VPC
in the clear. Point the HSL pool straight at the ingress's port 80 and the
middle VS, the server-ssl profile and the backend pool all disappear:

```bash
./f5-api.sh PATCH /mgmt/tm/ltm/pool/~Common~noname-security-hsl-https '{
  "monitor": "tcp",
  "members": [{"name": "10.0.8.100:80", "address": "10.0.8.100"}]}'

./f5-api.sh DELETE /mgmt/tm/ltm/virtual/~Common~noname-security-engine-https-vs
./f5-api.sh DELETE /mgmt/tm/ltm/pool/~Common~noname-security-engine-https-pool
./f5-api.sh DELETE /mgmt/tm/ltm/profile/server-ssl/~Common~noname-serverssl
./f5-api.sh DELETE /mgmt/tm/ltm/monitor/https/~Common~noname-https-monitor
./f5-api.sh POST   /mgmt/tm/sys/config '{"command":"save"}'
```

`monitor tcp` rather than `http` on that pool, because `/engine` is POST-only
and an HTTP monitor's `GET` would mark it down.

**This is not the configuration running on this stack.** If you apply it, update
this doc.

---

## Notes on adjacent configuration

**Engine sizing.** `Pending` pods are a CPU-request problem, fixed by one
supported value — not by the `nats-jetstream` patch older docs described:

```yaml
global:
  engine:
    engineSizing: "micro"
```

`medium` (the chart default) requests 17300m CPU and cannot fit on a 16 vCPU
`m5.4xlarge`; `micro` totals 8300m. See `docs/noname-engine.md`. The
`nats_jetstream:` values key some docs suggest for persistence **does not
exist** anywhere in chart v3.71.0 — setting it does nothing.

**`global.engine.hostNetwork: "true"`** is *not* required for HSL. It exists to
make `light-engine` bind UDP 4789 on the node for the **clone-pool / VXLAN**
integration, which is a *different and mutually exclusive* integration from this
one. Both target `10.0.8.100`, on different ports, which is an easy way to
confuse the two docs:

| | Port | Needs `hostNetwork` | Doc |
|---|---|---|---|
| HSL (this doc) | TCP 443 via the middle VS | no | `f5-hsl-integration.md` |
| Clone pool / VXLAN | UDP 4789 | **yes** | `noname-engine.md` Phase 3 |

Pick one. It is currently left enabled on this stack — harmless, and it keeps
the clone-pool option available.

**The pre-4.0.0 `HSL::open` workaround.** The current `send-to-noname.tcl`
already uses the `set nn_pool` variable form, so there is nothing to change.

---

## Updating the iRule

Download the new ZIP from the portal, then re-run the Step 7 upload as a `PATCH`
(same non-ASCII strip — the vendor file still has the `²`):

```bash
./f5-api.sh PATCH /mgmt/tm/ltm/rule/~Common~noname-hsl-https-logger \
  "$(cat /tmp/irule.json)"
./f5-api.sh POST /mgmt/tm/sys/config '{"command":"save"}'
```

No pool, profile, ingress or virtual-server changes are needed for an iRule
update — but re-check that the new file's `nn_pool` is still
`noname-security-hsl-https` and its `engine_hostname` is still `10.0.8.100`. A
regenerated integration can change both, and either one silently breaks
delivery.

---

## Uninstalling

Detach the iRule **before** deleting it — BIG-IP refuses to delete a rule that
is still referenced by a virtual server. Likewise delete the HSL pool and the
middle VS before the objects they reference.

```bash
cd ~/Downloads/aws-f5-vampi
set -a; source .f5-admin-password; set +a

./f5-api.sh PATCH  /mgmt/tm/ltm/virtual/~Common~vampi-vs '{"rules":[]}'
./f5-api.sh DELETE /mgmt/tm/ltm/rule/~Common~noname-hsl-https-logger
./f5-api.sh DELETE /mgmt/tm/ltm/pool/~Common~noname-security-hsl-https
./f5-api.sh DELETE /mgmt/tm/ltm/virtual/~Common~noname-security-engine-https-vs
./f5-api.sh DELETE /mgmt/tm/ltm/pool/~Common~noname-security-engine-https-pool
./f5-api.sh DELETE /mgmt/tm/ltm/profile/server-ssl/~Common~noname-serverssl
./f5-api.sh DELETE /mgmt/tm/ltm/monitor/https/~Common~noname-https-monitor
./f5-api.sh POST   /mgmt/tm/sys/config '{"command":"save"}'

# k3s
kubectl delete ingress noname-hsl-engine-ingress -n akamai-api-security

# Portal: Settings → Integrations → Traffic Sources → (your integration) → Delete
```
