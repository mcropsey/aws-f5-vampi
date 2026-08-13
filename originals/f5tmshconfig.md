# F5 BIG-IP tmsh Configuration — mcropsey Lab

## Lab IPs
| Resource | Value |
|---|---|
| F5 Mgmt EIP | `16.58.193.153` |
| F5 VIP EIP | `3.149.175.85` |
| VAmPI Public IP | `3.21.112.55` |
| VAmPI Private IP (pool member) | `10.0.1.195:5000` |

---

## 1 — SSH into F5
```bash
ssh -i ~/.ssh/mcropsey-key.pem admin@16.58.193.153
```

---

## 2 — Set Admin Password
> Note: You are already inside the tmsh shell — do not prefix commands with `tmsh`
```bash
modify auth user admin prompt-for-password
save sys config
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
create ltm pool vampi-pool monitor vampi-monitor members add { 10.0.1.195:5000 { address 10.0.1.195 } }
```

---

## 7 — Create Virtual Server
```bash
create ltm virtual vampi-vs destination 10.0.5.10:80 ip-protocol tcp pool vampi-pool profiles add { http { } } source-address-translation { type automap }
```
> Note: Warning about traffic-group-local-only is expected and harmless in a standalone lab.

---

## 8 — Add Static Route to VAmPI Subnet
> Required because F5 internal subnet (10.0.6.0/24) has no route to VAmPI (10.0.1.0/24) by default.
```bash
create net route to-vampi network 10.0.1.0/24 gw 10.0.6.1
```

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

---

## 11 — Test VIP from Laptop
```bash
curl http://3.149.175.85/
```

---

## 12 — Initialize VAmPI Database
```bash
curl http://3.149.175.85/createdb
```

---

## Network Design Reference
| Interface | BIG-IP Name | Private IP | Subnet |
|---|---|---|---|
| eth0 | mgmt | 10.0.7.20 | 10.0.7.0/24 |
| eth1 | 1.1 (external) | 10.0.5.10 | 10.0.5.0/24 |
| eth2 | 1.2 (internal) | 10.0.6.10 | 10.0.6.0/24 |
| VAmPI | pool member | 10.0.1.195 | 10.0.1.0/24 |
