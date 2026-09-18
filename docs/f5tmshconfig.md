# F5 BIG-IP tmsh Configuration — mcropsey Lab

> **This is the manual reference.** `02-configure-f5.sh` applies all of it for
> you. Keep this open when something breaks and you need to check state by hand.
>
> **IPs are no longer hardcoded.** Every value below marked `$…` comes from
> `lab-outputs.env`, written by `01-deploy-aws.sh`. Load them into your shell:
> ```bash
> source lab-outputs.env
> ```

## Lab IPs
| Resource | Value |
|---|---|
| F5 Mgmt EIP | `$F5_MGMT_IP` |
| F5 VIP EIP | `$F5_VIP_IP` |
| VAmPI Public IP | `$VAMPI_PUBLIC_IP` |
| VAmPI Private IP (pool member) | `$VAMPI_PRIVATE_IP:5000` |

---

## 1 — SSH into F5
```bash
ssh -i ~/.ssh/mcropsey-key.pem admin@$F5_MGMT_IP
```

---

## 2 — Set Admin Password
> Note: You are already inside the tmsh shell — do not prefix commands with `tmsh`
```bash
modify auth user admin prompt-for-password
save sys config
```
Non-interactive equivalent (what the script uses):
```bash
modify auth user admin password "<your-password>"
```

---

## 3 — Disable GUI Setup Wizard
Without this the TMUI opens to an interactive setup screen instead of the dashboard.
```bash
modify sys global-settings gui-setup disabled
save sys config
```

---

## 4 — Create VLANs
```bash
create net vlan external interfaces add { 1.1 { untagged } }
create net vlan internal interfaces add { 1.2 { untagged } }
```

---

## 5 — Create Self IPs
```bash
create net self self-ext address 10.0.5.10/24 vlan external allow-service none
create net self self-int address 10.0.6.10/24 vlan internal allow-service default
```

---

## 6 — Create Health Monitor
```bash
create ltm monitor http vampi-monitor interval 5 timeout 16 send "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" recv "200 OK"
```

---

## 7 — Create Pool
```bash
create ltm pool vampi-pool monitor vampi-monitor members add { $VAMPI_PRIVATE_IP:5000 { address $VAMPI_PRIVATE_IP } }
```

---

## 8 — Create Virtual Server
```bash
create ltm virtual vampi-vs destination 10.0.5.10:80 ip-protocol tcp pool vampi-pool profiles add { http { } } source-address-translation { type automap }
```
> Note: Warning about traffic-group-local-only is expected and harmless in a standalone lab.

---

## 9 — Routes

**9a. Static route to the VAmPI subnet.**
```bash
create net route to-vampi network 10.0.1.0/24 gw 10.0.6.1
```

**9b. Static route to the k3s subnet.** Required for F5 clone pool to reach the NoName sensor.
```bash
create net route to-k3s network 10.0.8.0/24 gw 10.0.6.1
```

To confirm:
```bash
list net route to-vampi
list net route to-k3s
```
> Note: `list net route <name>` returns `"route not found: <name>"` when absent
> — not the standard `"was not found"` message used for VLANs, self IPs, and
> other objects. Keep this in mind when scripting existence checks.

**9c. Default gateway.** Required for return traffic to internet clients. DHCP
on the external interface often creates this for you — check before adding it,
because a duplicate will be rejected:
```bash
list net route
# if there is no 'network default' entry:
create net route default-gw network default gw 10.0.5.1
```
> Skipping 8b is the classic silent failure in this lab: the pool goes green,
> `show ltm virtual` looks healthy, and `curl` to the VIP hangs forever. The
> monitor traffic originates on the internal side and never needs the default
> route, so nothing on the BIG-IP complains.

---

## 10 — Save Config
```bash
save sys config
```

---

## 11 — Verify Pool is Green
```bash
show ltm pool vampi-pool members
```
Pool member should show `Availability: available`.

If it is not, test the path from the BIG-IP itself:
```bash
run util bash -c "curl -sv --interface 10.0.6.10 http://$VAMPI_PRIVATE_IP:5000/"
```

---

## 12 — Test VIP from Laptop
```bash
curl http://$F5_VIP_IP/
```

---

## 13 — Initialize VAmPI Database
```bash
curl http://$F5_VIP_IP/createdb
```

---

## Network Design Reference
| Interface | BIG-IP Name | Private IP | Subnet |
|---|---|---|---|
| eth0 | mgmt | 10.0.7.20 | 10.0.7.0/24 |
| eth1 | 1.1 (external) | 10.0.5.10 | 10.0.5.0/24 |
| eth2 | 1.2 (internal) | 10.0.6.10 | 10.0.6.0/24 |
| VAmPI | pool member | `$VAMPI_PRIVATE_IP` | 10.0.1.0/24 |
| k3s node | NoName sensor target | `$K3S_PRIVATE_IP` | 10.0.8.0/24 |

---

## NoName Remote Engine — F5 Clone Pool

Once the engine is running on the k3s node and shows **connected** in the NoName
portal, wire F5 traffic mirroring with a clone pool pointed at the reserved sensor IP.

**Sensor IP: `10.0.8.100`** — ⚠ *not* reserved by CloudFormation. It is a
convention, added to the k3s node's `eth0` by hand as a `/32` (a `/24` breaks all
pod egress). See `docs/noname-engine.md` → "Sensor IP must not be primary".

Note this clone-pool path and the HSL path in `docs/f5-hsl-integration.md` are
**mutually exclusive**; the lab currently runs HSL.

For engine deployment steps, see `docs/noname-engine.md`.

```bash
create ltm pool noname-mirror-pool members add { 10.0.8.100:4789 { address 10.0.8.100 } }
modify ltm virtual vampi-vs clone-pools add { noname-mirror-pool { bind ingress } }
save sys config
```

Verify the clone pool is attached:
```bash
list ltm virtual vampi-vs clone-pools
```

The management interface sits on its own `10.0.7.0/24`, deliberately isolated
from VAmPI's `10.0.1.0/24`. Sharing a subnet between BIG-IP management and a
pool member creates routing ambiguity that is painful to diagnose.

---

## Useful state commands

```bash
list net vlan                      # VLANs and their interfaces
list net self                      # self IPs
list net route                     # routes — check for 'default' here
show ltm pool vampi-pool members   # pool health
show ltm virtual vampi-vs          # virtual server state and connection counts
show sys ready                     # config / license / provisioning readiness
tmsh -c "show sys log ltm" | tail  # LTM log, for monitor failures
```
