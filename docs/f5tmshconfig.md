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

## 3 — Create VLANs
```bash
create net vlan external interfaces add { 1.1 { untagged } }
create net vlan internal interfaces add { 1.2 { untagged } }
```

---

## 4 — Create Self IPs
```bash
create net self self-ext address 10.0.5.10/24 vlan external allow-service none
create net self self-int address 10.0.6.10/24 vlan internal allow-service default
```

---

## 5 — Create Health Monitor
```bash
create ltm monitor http vampi-monitor interval 5 timeout 16 send "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" recv "200 OK"
```

---

## 6 — Create Pool
```bash
create ltm pool vampi-pool monitor vampi-monitor members add { $VAMPI_PRIVATE_IP:5000 { address $VAMPI_PRIVATE_IP } }
```

---

## 7 — Create Virtual Server
```bash
create ltm virtual vampi-vs destination 10.0.5.10:80 ip-protocol tcp pool vampi-pool profiles add { http { } } source-address-translation { type automap }
```
> Note: Warning about traffic-group-local-only is expected and harmless in a standalone lab.

---

## 8 — Routes

**8a. Static route to the VAmPI subnet.** Required because the F5 internal
subnet (10.0.6.0/24) has no route to VAmPI (10.0.1.0/24) by default.
```bash
create net route to-vampi network 10.0.1.0/24 gw 10.0.6.1
```

**8b. Default gateway.** Required for return traffic to internet clients. DHCP
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

## 9 — Save Config
```bash
save sys config
```

---

## 10 — Verify Pool is Green
```bash
show ltm pool vampi-pool members
```
Pool member should show `Availability: available`.

If it is not, test the path from the BIG-IP itself:
```bash
run util bash -c "curl -sv --interface 10.0.6.10 http://$VAMPI_PRIVATE_IP:5000/"
```

---

## 11 — Test VIP from Laptop
```bash
curl http://$F5_VIP_IP/
```

---

## 12 — Initialize VAmPI Database
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
