# NoName / Akamai API Security — Remote Engine Deployment

> **This is the last step.** Complete the full lab deployment first:
> `01-deploy-aws.sh` → `02-configure-f5.sh` → `03-verify.sh` (VIP working,
> pool green). Only then proceed here.
>
> This doc covers two separate phases:
> - **Phase 1 (Manual — NoName portal):** Register the engine in the UI to
>   generate credentials. You do this yourself; it cannot be scripted.
> - **Phase 2 (k3s node):** Deploy the Helm chart using those credentials.
> - **Phase 3 (F5):** Wire the clone pool once the engine is connected.

---

## Topology

```
Internet → F5 VIP (10.0.5.10) → VAmPI pool member (10.0.1.x:5000)
                ↓ clone pool (ingress mirror) ← Phase 3
           NoName sensor IP 10.0.8.100:4789  ← secondary ENI IP on k3s node
                ↓
        k3s node (10.0.8.245)
        └── akamai-api-security namespace   ← Phase 2
            ├── engine pod      (connects OUTBOUND to NoName mgmt plane)
            ├── light-engine
            ├── router
            └── nginx
```

The engine connects **outbound** only — it phones home to the NoName management
plane. No inbound route from the NoName portal to the lab is needed.

---

## Phase 1 — NoName portal (manual)

Do this before touching the k3s node. You need credentials out of the portal
before the Helm chart can be configured.

1. Log into the NoName / Akamai API Security management UI at
   `https://michaelc-lab.nonamesec.com`
2. Navigate to **Settings → Engines → Add Engine**
3. Select **Remote Engine**
4. Fill in the engine name and any required fields
5. The portal generates and displays:
   - `engine_id`
   - `remote_keys_encoded`
   - `re_client_certificate`
   - `re_client_private_key`
6. Download or copy the generated `custom_values.yaml` snippet the portal
   provides — this becomes the content of `~/custom_values.yaml` on the k3s node
7. Note the management hostname and mTLS hostname shown in the portal
   (typically `<tenant>.nonamesec.com` and `<tenant>-mtls.nonamesec.com`)

**Do not proceed to Phase 2 until you have these values from the portal.**

---

## Phase 2 — k3s node Helm deployment

### SSH in

```bash
source lab-outputs.env
ssh -i ~/.ssh/mcropsey-key.pem "ec2-user@$K3S_PUBLIC_IP"   # 77.112.67.187
export KUBECONFIG=$HOME/.kube/config    # or /etc/rancher/k3s/k3s.yaml
```

> Use `~/.kube/config` (mode 600, copied from `/etc/rancher/k3s/k3s.yaml`) rather
> than `sudo helm`: helm's OCI registry credentials live in `ec2-user`'s
> `~/.config/helm`, so running helm as root fails to pull the chart. A
> non-interactive `ssh host 'helm ...'` also has no `KUBECONFIG`, which surfaces
> as `Kubernetes cluster unreachable: Get "http://localhost:8080/version"`.

### One-time node setup (already done on the current stack)

These steps are already complete on the running k3s node. Document them here
for re-deploys.

**NGINX ingress controller** — k3s is installed with `--disable traefik`.
NGINX is required; install it with `hostNetwork: true` so it binds to the
node's 80/443:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.service.type=ClusterIP \
  --set controller.kind=DaemonSet
```

Verify:
```bash
kubectl get ingressclass          # must show "nginx"
sudo ss -lntp | grep ':80\|:443' # nginx must hold both ports
```

**`/etc/hosts` entry** — k3s v1.36 rejects raw IPs as Ingress hostnames;
a DNS name is required. Add a loopback alias on the node:

```bash
echo '127.0.0.1 engine.michaelc-lab.local' | sudo tee -a /etc/hosts
```

**Disk space** — The CloudFormation template sets the k3s EBS root volume to
50 GB. If working with an older (10 GB) stack, expand it first — image pulls
for ~20 containers fill a 10 GB root and trigger pod evictions:

```bash
# From your laptop:
VOLUME_ID=$(aws ec2 describe-instances --region us-east-2 \
  --filters "Name=private-ip-address,Values=10.0.8.245" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text)
aws ec2 modify-volume --region us-east-2 --volume-id $VOLUME_ID --size 50

# On the k3s node once state = "optimizing":
sudo growpart /dev/nvme0n1 4
sudo xfs_growfs /
```

### Place the values file

Copy the `custom_values.yaml` snippet from the portal to `~/custom_values.yaml`
on the k3s node. See the **Values file structure** section below for the
required shape — the portal output often needs the keys reorganised under
`global:` before it will work with this chart version.

### Registry login

```bash
helm registry login us-central1-docker.pkg.dev \
  -u _json_key_base64 \
  -p '<imageCredentials.password from custom_values.yaml>'
```

### Deploy

```bash
helm upgrade --install akamai-api-security \
  oci://us-central1-docker.pkg.dev/noname-artifacts/nns-docker/helm/nonamesec \
  -n akamai-api-security --create-namespace \
  -f ~/custom_values.yaml \
  --version 'v3.71.0' \
  --timeout 15m
```

### Watch pods

```bash
kubectl get pods -n akamai-api-security -w
```

Expected running pods for a remote-engine-only install:

| Pod | Notes |
|---|---|
| `engine-*` | The remote engine — connects outbound to mgmt plane |
| `light-engine-*` | 2/2 containers |
| `router-*` | Traffic collector |
| `nginx-*` (2 replicas) | NoName UI reverse proxy |
| `nogate-*` | Auth gateway |
| `integrations-adapter-*` | |
| `nats-jetstream-0` | Message bus |

Once `engine-*` is Running, check the NoName portal — the engine should show
as **connected** within a minute or two.

---

## Phase 3 — F5 clone pool (after engine is connected)

> **This is one of two mutually exclusive F5 integrations. Pick one.** The clone
> pool mirrors raw packets to **UDP 4789** (VXLAN) and requires
> `global.engine.hostNetwork: "true"`. The alternative, **HSL**, has the F5 push
> structured HTTP telemetry to **TCP 80** via an iRule and needs no
> `hostNetwork`. Both target `10.0.8.100`, which makes them easy to confuse.
> **The lab currently runs HSL** — see `docs/f5-hsl-integration.md`. Only follow
> Phase 3 if you are deliberately switching to packet mirroring.

Only wire this once the engine shows connected in the portal. The sensor IP
`10.0.8.100` is **not** reserved on the ENI by CloudFormation, despite what
`01-deploy-aws.sh`, `docs/README-cloudformation.md` and the topology diagram
above imply — it is added to `eth0` by hand as a `/32` (see "Sensor IP must not
be primary"), and `lab-outputs.env` exports `NONAME_SENSOR_IP` regardless. On a
fresh deploy that address exists nowhere until you create it.

**Prerequisite: `global.engine.hostNetwork: "true"`.** Without it `light-engine`
stays on the pod network, nothing binds UDP 4789 on the node, and the clone pool
mirrors into a void with no error anywhere. Check before wiring the F5:

```bash
sudo ss -lnp | grep 4789
# want: udp UNCONN 0.0.0.0:4789 users:(("light_launcher",...))
```

`0.0.0.0` means it answers on `10.0.8.100` as well as the primary IP. The k3s SG
already allows all protocols from `10.0.6.0/24` (the F5 internal self IP), so no
security-group change is needed for the mirrored traffic.

```bash
ssh -i ~/.ssh/mcropsey-key.pem admin@$F5_MGMT_IP

create ltm pool noname-mirror-pool members add { 10.0.8.100:4789 { address 10.0.8.100 } }
modify ltm virtual vampi-vs clone-pools add { noname-mirror-pool { bind ingress } }
save sys config

# Verify
list ltm virtual vampi-vs clone-pools
```

---

## Values file structure

The chart uses subchart conditions keyed off `global.*`. Top-level keys
(`engine.enabled`, `noname.enabled`, etc.) are silently ignored by the subchart
activation logic. **All config must go under `global:`** or the subcharts
either fail to activate or fail to find their config.

Known gotchas in chart v3.69.0:

| Symptom | Root cause | Fix |
|---|---|---|
| `InvalidImageName: /image-name:v3.69.0` | `global.imageCredentials.namespaceRegistry` empty — images rendered with no registry prefix | Move `imageCredentials` under `global:` |
| `engine.engine_id is required` | Chart reads `global.engine.engine_id`; top-level `engine.engine_id` is ignored | Move all engine config under `global.engine:` |
| Noname/platform pods deploy despite `noname.enabled: false` | Subchart condition is `global.noname.enabled`; top-level key does nothing | Set `global.noname.enabled: false` |
| `INITIAL_INPUT_PASS must be defined` | Chart validates this field unconditionally even when noname disabled | Add `global.backend.secrets.INITIAL_INPUT_PASS` with any value |
| Pre-install hook timeout | `backend-jwt-token` job has `InvalidImageName` → never starts → hook times out | Fixed by moving `imageCredentials` under `global:` |
| Mass pod evictions on startup | 10 GB root EBS fills during ~20 image pulls | Expand to 50 GB (now in CFN template) |

Found additionally on v3.71.0:

| Symptom | Root cause | Fix |
|---|---|---|
| `engine-*` stuck `Pending`, `FailedScheduling: Insufficient cpu`; PVC `engine` stuck `Pending` too | Default `global.engine.engineSizing: "medium"` requests **17300m CPU** total — heavy-engine 7, NATS 5, light-engine 2.1, router HPA floor of 4 replicas × 1, nginx 2×0.5, nogate 1, adapter 0.2 — on a 16 vCPU `m5.4xlarge`. Cannot ever fit. | Set `global.engine.engineSizing: "micro"` (8300m/15G). `small` = 12300m/25G also fits. The `Pending` PVC is a *symptom*: `local-path` is `WaitForFirstConsumer`, so it cannot bind until the pod schedules. |
| Engine runs but never registers; log freezes mid-`Connecting to dal at https://…` with no error for many minutes | Assigning the sensor IP `10.0.8.100/24` makes it the **primary** address on `eth0` and demotes `10.0.8.245` to secondary. Flannel's rule is `-j MASQUERADE` with no `--to-source`, so it SNATs pod egress to the interface's *primary* address — but the EIP is associated only with `.245`, so the IGW drops every pod→internet packet. | Bind the sensor IP as a **`/32`** so it cannot claim the `/24`'s primary slot, and add an explicit SNAT rule ahead of flannel's. See "Sensor IP must not be primary" below. |

**Sensor IP must not be primary.** This one is nasty because the *node's* own
egress keeps working (its default route carries `prefsrc 10.0.8.245`) — only
forwarded pod traffic uses the primary address. Confirm it with conntrack while
curling from a pod; the giveaway is the reply tuple naming the wrong address:

```
SYN_SENT src=10.42.0.19 dst=1.1.1.1 ... [UNREPLIED] src=1.1.1.1 dst=10.0.8.100
                                        ^^^^^^^^^^^ should be 10.0.8.245
```

Do not put the sensor IP in `nmcli ipv4.addresses` — NetworkManager applies it
before the DHCP address, which is exactly what makes it primary. Add it after
the interface is up instead, as a `/32`:

```bash
# /etc/NetworkManager/dispatcher.d/50-noname-sensor-ip  (mode 755)
[ "$1" = "eth0" ] || exit 0
case "$2" in
  up|dhcp4-change)
    ip -4 addr show dev eth0 | grep -q '10\.0\.8\.100/32' \
      || ip addr add 10.0.8.100/32 dev eth0 ;;
esac
```

Plus a rule that is immune to address ordering, restored at boot by
`noname-pod-egress-snat.service`. Destinations inside `10.0.0.0/8` are excluded
so pod-to-pod (`10.42/16`), ClusterIP (`10.43/16`) and VPC traffic are untouched:

```bash
iptables -t nat -I POSTROUTING 1 -s 10.42.0.0/16 ! -d 10.0.0.0/8 \
  -j SNAT --to-source 10.0.8.245
```

Inbound VXLAN to `10.0.8.100:4789` is unaffected — it needs no NAT — so the
Phase 3 clone pool still works with the address as a `/32`.

**Two diagnostics that lie.** `/dev/tcp/host/443` probes inside the engine
container report *everything* blocked, including a known-good control host,
because that container's `sh` is not bash. Always include a control host. And
plain `curl` against the mTLS endpoint returns `rc=56` / `http=000` even when
the network is fine — that endpoint demands a client certificate, so `56` is not
evidence of a block. `michaelc-lab.nonamesec.com` returning `http=200` from
inside a pod is the real egress test.

Correct structure for a remote-engine-only deployment:

```yaml
global:
  noname:
    enabled: false       # disables backend, hasura, postgres, dal, rabbitmq, etc.
  platform:
    enabled: false
  active:
    enabled: false
  backend:
    secrets:
      INITIAL_INPUT_PASS: "..."   # required by chart even when noname disabled
  engine:
    enabled: true
    engineSizing: "micro"   # REQUIRED on a 16 vCPU node — default "medium"
                            # requests 17300m and never schedules. See table above.
    engine_id: "<from NoName portal>"
    remote_keys_encoded: "<from NoName portal>"
    re_client_certificate: "<from NoName portal>"
    re_client_private_key: "<from NoName portal>"
    env:
      COLLECTOR_TYPE: "remote"
      MANAGEMENT_IP: "<mgmt hostname from portal>"
      DATA_ORCHESTRATION_ENABLE_SSL: "true"
      DATA_ORCHESTRATION_ENABLE_SERVER_CERTIFICATE_VERIFICATION: "false"
      SETCAP: "false"
    volume:
      existingPVCName: null
  engine_platform:
    env:
      DATA_ORCHESTRATION_PUBLIC_HOSTNAME: "<mgmt hostname>"
      DATA_ORCHESTRATION_PUBLIC_HOSTNAME_MTLS: "<mtls hostname>"
  imageCredentials:
    enabled: true
    registry: "us-central1-docker.pkg.dev/noname-artifacts/nns-docker"
    namespaceRegistry: "us-central1-docker.pkg.dev/noname-artifacts/nns-docker"
    username: "_json_key_base64"
    password: "<GCP service account key base64>"
    email: "_json_key_base64"

ingress:
  enabled: true
  ingressClassName: nginx      # chart default is "alb" — must override
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "2000m"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
  hosts:
    - host: engine.michaelc-lab.local   # must be a DNS name, not an IP
      paths:
        - path: /
          pathType: Prefix
```

---

## Useful commands

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Pod status
kubectl get pods -n akamai-api-security

# Engine logs — check "connected" message and outbound connection to mgmt plane
kubectl logs -n akamai-api-security -l app=engine --tail=50

# Ingress (no ADDRESS shown is normal with hostNetwork)
kubectl get ingress -n akamai-api-security

# Uninstall cleanly
helm uninstall akamai-api-security -n akamai-api-security
kubectl delete namespace akamai-api-security --grace-period=0 --force
```
