# F5 BIG-IP HSL over HTTPS — NoName Integration

> **Prerequisite order:**
> 1. `01-deploy-aws.sh` → `02-configure-f5.sh` → `03-verify.sh` (VIP working)
> 2. NoName remote engine deployed and **connected** in the portal (`docs/noname-engine.md`)
> 3. Then this document

This integration enables the NoName / Akamai API Security engine to capture API
traffic from the F5 BIG-IP LTM using High-Speed Logging (HSL) over HTTPS. The
iRule captures every HTTP request/response passing through `vampi-vs` and
forwards it asynchronously to the engine for analysis.

---

## Traffic flow

```
Client
  │
  ▼
vampi-vs (10.0.5.10:80)
  │  iRule fires on HTTP_REQUEST / HTTP_RESPONSE
  │
  ▼ HSL::open -proto TCP
noname-security-hsl-https pool (10.0.5.20:8443)
  │
  ▼
noname-security-engine-https-vs (10.0.5.20:8443)
  │  HTTP profile client-side, serverssl server-side
  │  F5 terminates plain TCP from iRule, opens TLS to backend
  │
  ▼ HTTPS (TLS)
noname-security-engine-https-pool (10.0.8.100:443)
  │
  ▼
k3s NGINX ingress (hostNetwork, port 443 on 10.0.8.100)
  │  catch-all ingress: path /engine → router:8080
  │
  ▼ HTTP
router service (10.43.x.x:8080)
  │
  ▼ NATS
engine pod → michaelc-lab.nonamesec.com (outbound)
```

**Key addresses:**

| Object | Address | Notes |
|---|---|---|
| F5 external self IP | `10.0.5.10` | Self IP — cannot be used as VS destination |
| Engine VS (loopback) | `10.0.5.20:8443` | Local VS; HSL connects here |
| NoName sensor IP | `10.0.8.100:443` | Secondary ENI IP on k3s node; stable across deploys |
| k3s primary IP | `10.0.8.171` | Node IP |

---

## Step 1 — Configure the integration profile (NoName portal — manual)

1. Log into the NoName portal at `https://michaelc-lab.nonamesec.com`
2. Go to **Settings → Integrations → Traffic Sources → Add Integration**
3. Select the **F5** tile
4. Enter a name, select **HSL**, and select the remote engine
5. Click **Create**
6. **Download the ZIP file** — extract it to get `send-to-noname.tcl`

The ZIP contains the iRule pre-configured with your integration credentials
(`source_key`, `engine_hostname`, etc.). Do not edit the file.

---

## Step 2 — k3s: catch-all ingress for `/engine`

The iRule sends traffic with `Host: 10.0.8.100` (the sensor IP). The existing
ingress only matches `engine.michaelc-lab.local`, so a catch-all rule is needed.
k3s v1.36 rejects raw IPs as ingress hosts, making a no-host catch-all the
correct solution.

```bash
ssh -i ~/.ssh/mcropsey-key.pem ec2-user@3.136.119.100
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

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

Verify:
```bash
kubectl get ingress -n akamai-api-security
# noname-hsl-engine-ingress should show HOSTS: *
```

---

## Step 3 — k3s: fix nats-jetstream CPU scheduling

The chart's default `nats-jetstream` CPU request is **5 cores**. Combined with
`heavy-engine` (7 cores) and other pods, this exceeds the node's 16 allocatable
cores and leaves nats-jetstream `Pending`. The router depends on NATS and will
crash-loop until it's up.

```bash
kubectl patch statefulset nats-jetstream -n akamai-api-security --type='json' \
  -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"1"},
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"2"}
  ]'
```

Verify all pods are running:
```bash
kubectl get pods -n akamai-api-security
# All should show Running/Ready — especially nats-jetstream-0 and router-*
```

---

## Step 4 — F5: create engine pool

Pool pointing at the NoName sensor IP on the k3s node. Using a `tcp` monitor
(not `https`) because the NGINX ingress `/engine` path returns 200 but the
endpoint is POST-only — a `tcp` check confirms the port is open without
relying on HTTP response content.

```bash
ssh -i ~/.ssh/mcropsey-key.pem admin@$F5_MGMT_IP

create ltm pool noname-security-engine-https-pool {
    monitor tcp
    members add { 10.0.8.100:443 { address 10.0.8.100 } }
}
```

---

## Step 5 — F5: create engine virtual server

This VS is the HTTPS proxy. The iRule never connects here directly — it goes
through the HSL pool (Step 6). The VS receives plain TCP from the HSL pool,
applies the `serverssl` profile to open TLS to the backend engine pool, and
proxies the HTTP payload through.

The destination `10.0.5.20:8443` is in the external subnet (`10.0.5.0/24`) but
is **not** a self IP (`10.0.5.10`), so BIG-IP accepts it as a VS address.

```bash
create ltm virtual noname-security-engine-https-vs {
    destination 10.0.5.20:8443
    ip-protocol tcp
    pool noname-security-engine-https-pool
    profiles add {
        http { }
        serverssl { context serverside }
    }
    source-address-translation { type automap }
}
```

---

## Step 6 — F5: create HSL pool

This is what the iRule's `HSL::open` connects to. It points at the engine VS
created in Step 5. The `tcp_half_open` monitor checks TCP reachability without
completing a full handshake.

```bash
create ltm pool noname-security-hsl-https {
    monitor tcp_half_open
    members add { 10.0.5.20:8443 { address 10.0.5.20 } }
}
```

---

## Step 7 — F5: upload iRule (TMUI — manual)

The iRule contains multi-line TCL with `proc` definitions that are difficult to
create via tmsh command line. Use the browser UI:

1. Go to `https://<F5_MGMT_IP>`
2. **Local Traffic → iRules → iRule List → Create**
3. Set **Name** to `noname-hsl-https-logger`
4. Paste the full contents of `send-to-noname.tcl` into **Definition**
5. Click **Finished**

> The iRule file comes from the ZIP downloaded in Step 1. It is pre-configured
> with your integration credentials — do not edit it unless instructed by the
> NoName team.

**Known issue with iRule versions before 4.0.0:** If the iRule contains the
line `set nn_hsl [HSL::open -proto TCP -pool noname-security-hsl-https]`,
change it to:
```tcl
set nn_pool noname-security-hsl-https
set nn_hsl [HSL::open -proto TCP -pool $nn_pool]
```

---

## Step 8 — F5: attach iRule to vampi-vs

```bash
modify ltm virtual vampi-vs rules { /Common/noname-hsl-https-logger }
save sys config
```

> **Note:** This replaces the rules list. If `vampi-vs` had existing iRules,
> list them first (`list ltm virtual vampi-vs rules`) and include them all in
> the `rules { }` block.

---

## Verification

### F5 — iRule is firing

```bash
show ltm rule noname-hsl-https-logger
```

Look for **Executions Total** incrementing on `HTTP_REQUEST` and
`HTTP_RESPONSE` events. Zero failures means HSL connections are succeeding.

### F5 — pools are green

```bash
show ltm pool noname-security-engine-https-pool members
show ltm pool noname-security-hsl-https members
```

Both should show `Availability: available`.

### k3s — router is receiving and pushing traffic

```bash
kubectl logs -n akamai-api-security -l app=router --tail=20
```

Look for telemetry like:
```
"total_messages_pushed_to_ingest": N
"pushed_to_nats": N
```

Where N matches (roughly) the iRule execution count. Traffic is flowing
end-to-end when these numbers are non-zero and incrementing.

### NoName portal

The integration connector status changes from **pending** to **online** once
the engine processes traffic and sends a heartbeat to the management plane.
This can take 1–2 minutes after the first traffic flows. Generate a few
requests to the VIP to trigger it:

```bash
source lab-outputs.env
curl http://$F5_VIP_IP/
curl http://$F5_VIP_IP/users/v1
curl http://$F5_VIP_IP/createdb
```

---

## Troubleshooting

### Connector stays "pending" in portal

1. Check iRule execution count — if zero, iRule is not attached or no traffic
   has hit the VIP
2. Check engine pool health (`show ltm pool noname-security-engine-https-pool`)
   — if down, F5 can't reach `10.0.8.100:443`; verify the k3s route exists on
   the F5 (`list net route to-k3s`)
3. Check router logs for NATS connection errors
4. Check engine logs:
   ```bash
   kubectl logs -n akamai-api-security -l app=engine --tail=50
   ```
   Look for connection errors to `michaelc-lab.nonamesec.com`

### nats-jetstream Pending after redeploy

The chart defaults give nats-jetstream a 5-core CPU request. On a fresh
install, re-apply the patch in Step 3.

To persist the fix across helm upgrades, add to `custom_values.yaml`:
```yaml
# (inside the global or top-level nats_jetstream section - check chart values)
nats_jetstream:
  resources:
    requests:
      cpu: "1"
    limits:
      cpu: "2"
```

### iRule fires but router shows no messages

Verify the catch-all ingress exists and routes correctly:
```bash
kubectl get ingress -n akamai-api-security
# noname-hsl-engine-ingress should show HOSTS: *

# Test the endpoint directly from the k3s node
curl -sk https://10.0.8.100/engine -o /dev/null -w '%{http_code}'
# Should return 200
```

### F5 LTM log errors

```bash
tail -50 /var/log/ltm
# Or via tmsh:
tmsh -c "show sys log ltm" | tail -20
```

---

## Updating the iRule

When a new version of the integration is available:

1. Download the new ZIP from **Settings → Integrations** in the portal
2. **Local Traffic → iRules → noname-hsl-https-logger**
3. Replace the Definition content with the new `send-to-noname.tcl`
4. Click **Update**

No pool, VS, or pool changes are required for an iRule update.

---

## Uninstalling

```bash
# 1. Remove iRule from vampi-vs
modify ltm virtual vampi-vs rules none
save sys config

# 2. Delete F5 objects (optional)
delete ltm pool noname-security-hsl-https
delete ltm virtual noname-security-engine-https-vs
delete ltm pool noname-security-engine-https-pool
delete ltm rule noname-hsl-https-logger
save sys config

# 3. Remove k3s catch-all ingress (optional)
kubectl delete ingress noname-hsl-engine-ingress -n akamai-api-security

# 4. Delete integration profile in NoName portal
# Settings → Integrations → Traffic Sources → (your integration) → Delete
```
