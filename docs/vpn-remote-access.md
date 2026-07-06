# Remote access (VPN) to the homelab

**Status: OPTION A EXECUTED (owner, 2026-07-06).** The owner enabled the
native WireGuard server on the GT-AX11000 (appendix below) and verified remote
access from a hotspot. As-built notes: the stock ASUS WireGuard UI does not
accept a per-peer `DNS =` value — set DNS **client-side** instead (WireGuard
app → Edit tunnel → DNS servers `192.168.50.180, 192.168.50.144`, replacing
any auto-filled `192.168.50.1`); split tunnel `AllowedIPs = 192.168.50.0/24`.
Option B (Tailscale subnet router) remains the recommended path for P5
remote-site connectivity and as a future second path; it is NOT set up today.

Original investigation below, kept as reference. This runbook is the deliverable of
Trello card #72. Every step that touches the router, a Tailscale account, the
NAS, or a client device needs **owner hands**; the exact click-paths are below.
No cluster manifests, DNS zone edits, or k3s changes are required (verified —
see "What is already in place").

## Decision

**Recommended: Option B — Tailscale subnet router on the DS918 NAS
(192.168.50.144, wired).**
Option A (native WireGuard server on the GT-AX11000 router) is fully viable
(no CGNAT — see evidence) and documented in the appendix as an optional,
completely independent second/emergency path. Option C (cluster-hosted VPN) is
rejected.

### CGNAT verdict: NOT behind CGNAT (evidence, checked 2026-07-03)

- Public IP seen by the internet from inside the LAN: `109.134.145.145`
  (`curl ifconfig.me` from WSL) — a real public address, not `100.64.0.0/10`.
- `traceroute 109.134.145.145` from the LAN terminates at **hop 2 = the Asus
  router itself answering as 109.134.145.145**. The router's WAN interface
  holds the public IP directly → no carrier NAT in front of it.
- (`traceroute 8.8.8.8` shows an RFC1918 hop `10.24.1.81` *after* the router;
  that is ordinary ISP-internal addressing on transit links, not CGNAT — the
  hop-2 result above is the decisive test.)

Consequence: router-terminated WireGuard with ASUS DDNS **would** work. The
recommendation below is still Tailscale, for reasons other than reachability.

### Comparison

| | A. WireGuard on GT-AX11000 | B. Tailscale subnet router on DS918 | C. Cluster-hosted WireGuard |
|---|---|---|---|
| Reachability | Needs public IP (✓ we have one) + DDNS + open WAN UDP port | No inbound port at all; NAT traversal + relay fallback | Needs public IP + port-forward to a Cilium LB VIP |
| Cluster dependency | None | None (NAS is independent of k3s) | **Total — dead exactly when the cluster is broken** |
| Wired-host rule | ✓ router | ✓ DS918 is wired | ✗/✓ depends on node scheduling |
| Attack surface | Open UDP port on WAN, router firmware quality | No listening WAN port; WireGuard data plane, vendor control plane for key exchange | Open WAN port + cluster ingress path |
| Device management | Manual key pairs in router UI, no revocation UX beyond delete | Admin console: add/revoke per device, key expiry, ACLs | Manual configs (+ SealedSecrets churn) |
| Split DNS | Per-client `DNS =` line in each .conf | Central, in admin console, applies to all clients | Per-client |
| DDNS / IP change | Needs ASUS DDNS; brief outage on IP change | Irrelevant — control plane finds the endpoint | Needs DDNS |
| Third-party dependency | None | Tailscale coordination servers (data stays E2E WireGuard) | None |
| Cost | Free | Free (Personal tier: 3 users / 100 devices) | Free |
| Firmware prerequisite | Asuswrt 388.x+ (WireGuard server UI) — **owner must confirm installed version** | DSM 7 + Tailscale package (DS918+ is supported) | n/a |

**Why B over A:** central device add/revoke, no exposed WAN port, no DDNS
dependency, central split DNS (one place instead of every client config), and
it keeps working if the ISP ever moves the line behind CGNAT. The third-party
control-plane dependency is the trade-off; traffic itself is end-to-end
WireGuard. A is kept as the documented emergency path precisely because it has
*zero* third-party dependency — the two are complementary, not exclusive.

**Why not C:** remote access must be most reliable when things are broken. A
cluster-hosted VPN depends on k3s, Cilium, the LB VIP pool and Argo CD — the
exact components an emergency session would be trying to fix. It also puts
WireGuard keys into SealedSecrets churn for no gain. Rejected.

## Architecture (recommended path)

```
phone / laptop (Tailscale client, 100.x.y.z)
      │  WireGuard tunnel (direct, NAT-traversed; DERP relay fallback)
      ▼
DS918 NAS 192.168.50.144 (wired)  — tailscaled, subnet router
      │  advertises 192.168.50.0/24
      ▼
LAN 192.168.50.0/24
  ├── 192.168.50.200  gateway VIP  (grafana / argocd / influxdb / hermes .lab.local)
  ├── 192.168.50.180  coredns-lab VIP — split-DNS target for lab.local
  ├── 192.168.50.144  DS918 (DNS2 slave, SMB)
  ├── 192.168.50.18   vesta — Home Assistant :8123 + MQTT
  └── 192.168.50.151-.156  k3s nodes (SSH; .151 = kube-API)

Split DNS (Tailscale admin console):
  lab.local → 192.168.50.180, 192.168.50.144
```

## What is already in place (verified 2026-07-03, read-only)

- **`vesta.lab.local` already exists** in the zone-in-git
  (`.config/lab/coredns-lab.yaml`: `vesta IN A 192.168.50.18`) and resolves on
  both .180 (primary) and .144 (DS918 slave). **No zone change needed.**
- **kube-API cert SANs already include `k3s.lab.local`** (checked with
  `openssl s_client` against 192.168.50.151:6443): `k3s-master01.local`,
  `k3s.lab.local`, `kubernetes*`, `localhost`, IPs `10.43.0.1`, `127.0.0.1`,
  `192.168.50.151`, `192.168.50.160`, `::1`. `k3s.lab.local` resolves to .151
  at .180. **kubectl over the VPN works today** with
  `server: https://k3s.lab.local:6443` — no k3s `tls-san` change needed.
  (Card #31's k3s.lab.local SAN is evidently already done. `.160` in the SANs
  is unexplained — possibly a planned API VIP; harmless.)
- Router model confirmed from the login page: **ASUS ROG Rapture GT-AX11000**.
  Installed firmware version is not readable without logging in — owner step.

### The `vesta.local` / mDNS caveat

Bare `vesta.local` is an mDNS-style name. It happens to resolve through
.180/.144 today only because coredns-lab's catch-all forwards to the router.
Over a tunnel:

- A split-DNS entry `vesta.local → 192.168.50.180` would work on **Android,
  Windows and Linux** clients.
- **Apple devices (iOS/macOS) treat `.local` as mDNS-only** (RFC 6762) and
  will not reliably send unicast DNS queries for it — split DNS for
  `vesta.local` will NOT work there, and no A record on .180 changes that.

**Resolution: use `vesta.lab.local:8123` for Home Assistant when remote.** It
is covered by the single `lab.local` split-DNS entry and works on every
platform. (Optionally also add the `vesta.local` split-DNS entry for the
non-Apple devices' convenience.)

## Owner click-path (Option B — Tailscale)

### 1. Create the tailnet

1. Go to <https://login.tailscale.com/start> and sign up with an identity
   provider (e.g. Microsoft for `jellebens@outlook.com`). The free **Personal**
   plan (3 users / 100 devices) is enough.
2. You land in the admin console at <https://login.tailscale.com/admin>.

### 2. Install Tailscale on the DS918

1. DSM → **Package Center** → search **Tailscale** → **Install** (Synology
   community/partner package; DS918+ / DSM 7 is supported. If it is not
   listed, download the `apollolake` `.spk` from
   <https://pkgs.tailscale.com/stable/#spks> and use *Manual Install*).
2. Open the Tailscale app in DSM and **Log in** — a browser window authorizes
   the NAS into your tailnet.

### 3. Advertise the LAN subnet (needs SSH — the DSM UI cannot set this)

1. DSM → **Control Panel → Terminal & SNMP → Enable SSH** (temporarily, if it
   is off).
2. SSH in as a DSM admin user and run:

   ```sh
   sudo tailscale up --advertise-routes=192.168.50.0/24 --accept-dns=false --reset
   ```

   - `--advertise-routes=192.168.50.0/24` — offers the whole LAN to the tailnet.
   - `--accept-dns=false` — the NAS keeps its own resolver (it must NOT point
     at itself through the tunnel; it is the lab DNS slave).
3. Disable SSH again if you enabled it just for this.

### 4. Approve the route + pin the node (admin console)

1. **Machines** → the `ds918` row shows *"Subnet routes: awaiting approval"* →
   **⋯ → Edit route settings** → tick **192.168.50.0/24** → Save.
2. Same **⋯** menu → **Disable key expiry** for the NAS (it is infrastructure;
   default expiry is 180 days and would silently kill remote access).
   Leave key expiry ON for phones/laptops.

### 5. Split DNS

1. Admin console → **DNS** tab.
2. Under **Nameservers → Add nameserver → Custom**:
   - Nameserver: `192.168.50.180`
   - Enable **Restrict to domain** ("split DNS") → domain: `lab.local`
3. Repeat with nameserver `192.168.50.144` for the same domain `lab.local`
   (fallback: the DS918 zone slave).
4. Do **not** enable "Override local DNS". MagicDNS may stay on or off —
   irrelevant to this setup.
5. Optional: the same for domain `vesta.local` → `192.168.50.180` (helps
   Android/Windows/Linux; Apple devices ignore it — use `vesta.lab.local`).

### 6. Install clients

1. Phone: install the Tailscale app (iOS App Store / Google Play), log in with
   the same identity, toggle the VPN on. Android: check **Use Tailscale
   subnets** in the app settings (iOS routes subnets automatically).
2. Laptop: install from <https://tailscale.com/download>, log in. If it is a
   Linux CLI machine, run `sudo tailscale up --accept-routes` (the
   `--accept-routes` flag is needed on Linux only).

### 7. Verify (from a phone hotspot, NOT the home Wi-Fi)

```sh
tailscale status                          # ds918 listed, direct or relay
nslookup grafana.lab.local                # → 192.168.50.200 (split DNS works)
# then in a browser / terminal:
https://grafana.lab.local                 # gateway VIP service
http://vesta.lab.local:8123               # Home Assistant
ssh <user>@192.168.50.151                 # node SSH
kubectl --server https://k3s.lab.local:6443 get nodes   # kube-API (cert SAN OK)
smb://192.168.50.144                      # NAS shares
```

### kubeconfig for remote use

Copy the existing kubeconfig and set the server to the DNS name (the cert SAN
`k3s.lab.local` is already present, so no `--insecure-skip-tls-verify`):

```yaml
clusters:
  - cluster:
      server: https://k3s.lab.local:6443
      certificate-authority-data: <unchanged>
```

## Day-2 operations

### Adding a device

Install the client, log in with the tailnet identity, done. Check it appears
under **Machines**. Nothing to configure on the NAS or router.

### Revoking a device (lost phone, decommissioned laptop)

Admin console → **Machines** → device row → **⋯ → Remove machine**. The node
key is invalidated immediately; the device cannot reconnect without a fresh
login. (For a suspected-compromised *account*, also revoke its sessions under
**Settings → User management**.)

### Key rotation

- Client devices: node keys expire and re-authenticate automatically every 180
  days (default). Forcing an early rotation = **⋯ → Expire key** on the
  machine, then re-login on the device.
- The NAS has key expiry disabled (step 4); rotate it deliberately once a year
  with **Expire key** + re-login in the DSM Tailscale app.
- WireGuard session keys underneath rotate automatically and frequently; no
  action.

### Security notes

- Authentication is SSO + per-device node keys only — no passwords/PSKs exist
  in this design. **No VPN secret of any kind lives in this repo** (and none
  may ever be committed; if a cluster-side secret is ever needed, it must be a
  SealedSecret via kubeseal, controller `sealed-secrets` in ns `argocd`).
- Default tailnet ACL is allow-all *within your own tailnet*; for a
  single-owner tailnet this is acceptable. Optional hardening: an ACL that
  only allows the phone/laptop tags to reach `192.168.50.0/24`, and/or
  [Tailnet Lock](https://tailscale.com/kb/1226/tailnet-lock) so Tailscale's
  control plane cannot silently add nodes.
- The NAS remains the single tunnel entry point; it is wired (AiMesh wireless
  backhaul fragility does not apply) and independent of the k3s cluster.
- Nothing in this design touches Cilium NetworkPolicies, CoreDNS config, or
  any live cluster state. zeus's connectivity (HA/MQTT, InfluxDB, NAS, public
  APIs) is unaffected.

## Appendix — Option A: native WireGuard server on the GT-AX11000

Viable today (public IP confirmed). Recommended only as an *additional*,
Tailscale-independent emergency path, or if the owner prefers zero third-party
involvement.

1. **Confirm firmware**: router UI (<http://192.168.50.1>) → login →
   **Administration → Firmware Upgrade**. The WireGuard server UI needs
   Asuswrt **3.0.0.4.388.x or newer** (or Asuswrt-Merlin for the GT-AX11000).
   Update if older. *(Installed version was not readable from the LAN without
   credentials — this check is the first owner step.)*
2. **DDNS**: **WAN → DDNS** → enable, server `WWW.ASUS.COM`
   (`<name>.asuscomm.com`), pick a hostname. Free, built in.
3. **VPN server**: **VPN → VPN Server → WireGuard VPN** → **Enable**. Keep the
   default listen port (51820/udp) or pick a random high port. The router
   generates the server key pair itself (the UI on this firmware creates a
   port-forward/firewall pass-through automatically — no manual port-forward
   rule needed).
4. **Add a client**: in the same page **Add** a peer — the router generates
   the client key pair and shows a `.conf` + QR code. Per client set:
   - `AllowedIPs = 192.168.50.0/24` (split tunnel — LAN only; NOT `0.0.0.0/0`
     unless you want full-tunnel browsing via home)
   - `DNS = 192.168.50.180, 192.168.50.144` in the client `.conf` (there is no
     central split DNS — remote names resolve because the lab resolver is the
     tunnel DNS; `vesta.lab.local` works, bare `.local` names again do not on
     Apple devices).
5. Import the QR/`.conf` into the WireGuard app on the phone/laptop and test
   from a hotspot (same verification list as above).
6. **Key handling**: the `.conf` files contain private keys — store them in a
   password manager only. **Never commit a `.conf` to this repo.** Revoking a
   device = delete its peer in the router UI. Rotation = delete + re-add the
   peer.

Trade-offs vs Tailscale: per-device key handling is manual, revocation is
router-UI-only, an open WAN UDP port exists, DDNS adds a moving part, and an
ISP IP change drops sessions until DDNS re-converges.

## Open items for the owner (also in the Trello card)

1. Decide: Option B (recommended), Option A, or both.
2. If B: execute click-path steps 1–7 above (account, NAS package, SSH
   `tailscale up`, route approval, split DNS, clients, hotspot test).
3. If A (also): confirm GT-AX11000 firmware ≥ 388.x, then appendix steps 2–6.
4. Report back the hotspot test results; then this card can close.
