# dhcp-hook — `/etc/hosts` aligned with the IP obtained via DHCP

A `dhclient` exit hook that, at every lease, rewrites the node hostname line in `/etc/hosts` with the IP
just obtained on `vmbr0`, keeping the FQDN set at installation, `<hostname>.<domain>`. When the IP
changes, it has the node certificate, `pve-ssl.pem`, regenerated so that its SAN contains the new IP. An
enter hook forces the same domain into `/etc/resolv.conf`, which PVE uses for the certificate FQDN. The
domain is not written in the code: it is derived from the node FQDN.

## Purpose and scope

Proxmox VE requires the hostname to resolve, via `/etc/hosts`, to the node's real IP. The installer
writes a static configuration, and no component updates `/etc/hosts` when the IP changes. On a
micro-node that moves from the preparation site to a destination network using DHCP, this leaves the
hostname resolving to an address that no longer exists.

Scope:

- **single** PVE node: no cluster, no HA, no Ceph;
- management bridge **`vmbr0` on DHCP**, with no `address` or `gateway`;
- **fixed FQDN**, set at installation and independent of the domain provided by DHCP.

Out of scope: IP, subnet, gateway and DNS, which `dhclient-script` applies by itself; networks without
DHCP (see §Known limits). A custom certificate (`pveproxy-ssl.pem`, for example ACME) is not touched.

## Requirements

- Proxmox VE 9.x on Debian 13 (trixie).
- `ifupdown2` as network stack.
- `isc-dhcp-client` as the **actual** DHCP client: it is the one invoked by the `dhcp.py` addon of
  `ifupdown2`. `dhcpcd-base` may be installed but is not used; `systemd-networkd` and NetworkManager
  must be inactive.

## How it works

`dhclient-script` runs the scripts in `/etc/dhcp/dhclient-exit-hooks.d/` with `source` (`. $script`,
function `run_hook`), in the same shell process. This sets the writing constraints of the hook:

- **`exit` is forbidden**: it would terminate `dhclient-script` itself. The hook works inside a function
  and leaves it with `return`;
- every name it defines stays in the environment of the following hooks: at the end the hook removes its
  own function and variables (`unset`);
- the file must not be executable and **must have no extension**: `run-parts --list` only accepts names
  made of `[A-Za-z0-9_-]` and silently ignores the others.

### When the hook acts

The hook acts only if all conditions are true; otherwise it returns without touching anything.

| Variable | Condition |
|---|---|
| `$interface` | equal to `PVEH_IFACE` (`vmbr0`) |
| `$exit_status` | `0`, i.e. `dhclient-script` applied the configuration without errors |
| `$reason` | one of `BOUND`, `RENEW`, `REBIND`, `REBOOT`, `TIMEOUT` |
| `$new_ip_address` | not empty |
| `/etc/hostname` | first line not empty; if empty the hook logs it and changes nothing |

`TIMEOUT` is included because it is the case where `dhclient-script` reuses a previous lease that is
still valid: the applied IP must be written to `/etc/hosts` then too.

### Node domain

The domain is **the part of the FQDN that follows the hostname**: for `<hostname>.site.example.net`,
`site.example.net`. The whole right-hand part is taken, not a single label, so a change in the naming
convention does not touch the code.

The source is the FQDN set at installation, which the Proxmox VE installer writes to `/etc/hosts` in the
form `<IP> <FQDN> <hostname>`: `/etc/hostname` only carries the short name. Step 3 of the installation
verifies it on the node. Both hooks look, in the non-commented lines of `/etc/hosts`, for the first name
starting with `<hostname>.` and strip the hostname and any trailing dot. `pve-hosts` rewrites that line
keeping the FQDN, so the domain stays readable at every following lease.

If `/etc/hosts` contains no FQDN for the hostname, the two hooks **do not invent a domain**: `pve-hosts`
writes the line without FQDN, `<IP> <hostname>`, because the aligned IP is what PVE requires, and
`pve-hosts-domain` keeps the DHCP `domain-name`. Both log it to the journal, tag `pve-hosts`. To fix it,
write the FQDN by hand in the hostname line.

### Rewriting `/etc/hosts`

1. Reads the short hostname from the first line of `/etc/hostname`, derives the domain (§Node domain)
   and builds `<IP> <hostname>.<domain> <hostname>`.
2. With `awk` copies `/etc/hosts` to a temporary file in the same directory (`/etc/.hosts.XXXXXX`):
   - comments pass unchanged;
   - **every line containing the short hostname** in a field other than the first is removed — so
     duplicates and lines with stale IPs too;
   - the new line is inserted **once, right after the first `127.0.0.1` line**, or at the end if that
     line is missing.
3. **Writes only if the content changes**: if the temporary file is identical to `/etc/hosts` it deletes
   it and returns. A second run with the same IP is therefore a no-op, with inode and mtime unchanged.
4. Otherwise sets `root:root` and `0644` on the temporary file and replaces `/etc/hosts` with `mv -f`:
   the replacement is **atomic**, because it happens within the same filesystem.
5. Logs the event to the journal with tag **`pve-hosts`**:
   `reason=<reason> <old IP> -> <new IP>: /etc/hosts updated`.
6. Calls **`pvebanner`** to regenerate `/etc/issue`, the console banner that shows the management URL
   with the IP. It is needed because `pvebanner.service` runs at boot before the network is up (see
   §Facts).
7. Asks systemd to start **`pve-hosts-cert.service`**, if the unit is installed, with
   `systemctl --no-block`: see §Node certificate.

Every error — a failing `mktemp`, a missing hostname — returns `0`: a failing hook must not interrupt the
network configuration.

### Search domain

`dhclient-script` rewrites `/etc/resolv.conf` at every lease (there is no `resolvconf` nor
systemd-resolved on the node), and derives the `domain` and `search` lines from the `domain-name` and
`domain-search` of the host network DHCP. Without `domain-name` the `search` line with the node domain
disappears; with another domain, that one appears.

The enter hook **`pve-hosts-domain`**, in `/etc/dhcp/dhclient-enter-hooks.d/`, forces the node domain
(§Node domain) for `vmbr0` only, at the same `reason` values as `pve-hosts`: it assigns
`new_domain_name`, which replaces the received value or provides it if DHCP does not. Whatever the host
network, the result is:

```
domain <node domain>
search <node domain> [domain-search domains of the host network]
```

`dhclient-script` puts `domain-name` at the head of the `search` list if it is not already there, so the
search domains of the host network remain usable, after the node one. DNS servers, IP and gateway keep
coming from DHCP.

It serves two purposes: short names resolved by the node itself are completed with the node domain, and
above all the **certificate FQDN** of the node, which PVE derives from this line (§Node certificate), is
the one set at installation.

It is an **enter** hook because `dhclient-script` sources the hooks in `dhclient-enter-hooks.d` before
applying the lease and calling `make_resolv_conf`, while exit hooks run after `/etc/resolv.conf` has been
written. The same writing constraints as `pve-hosts` apply: no `exit`, no extension, `unset` of its own
names — except `new_domain_name`, which is the result.

Earlier development versions forced the domain with `supersede domain-name` in `dhclient.conf`, with the
value written in the file: replaced because `dhclient.conf` cannot derive it from the FQDN, and every
node would have needed a different block. `install`, `uninstall` and the rollback remove that block if
present.

### Node certificate

`pve-ssl.pem` is the certificate presented by `pveproxy` (8006) and `spiceproxy` (3128), signed by the
node CA `pve-root-ca.pem`. Its SAN carries the node IP **at the time it was generated**, and Proxmox VE
regenerates it only if missing: `pveproxy.service` runs `pvecm updatecerts --silent` at every start,
without `--force`.

Two components besides the hook:

- **`pve-hosts-cert`**, a script installed in `/usr/local/sbin`. Reads the hostname from
  `/etc/hostname`, resolves it with `getent ahosts` and takes the first non-loopback address — the same
  rule PVE uses to choose the IP for the SAN. Derives the expected FQDN as PVE does: hostname plus the
  first domain of the last `search` or `domain` line of `/etc/resolv.conf`. If the SAN of
  `/etc/pve/local/pve-ssl.pem` already contains `IP Address:<IP>` and `DNS:<FQDN>` it exits doing
  nothing; if `/etc/resolv.conf` has no domain it checks the IP only. Otherwise it runs
  `pvecm updatecerts --force`, verifies that the new SAN contains IP and FQDN and reloads `pveproxy` and
  `spiceproxy` with `systemctl try-reload-or-restart`. Logs with tag **`pve-hosts-cert`**; exits with a
  non-zero code if it cannot verify or regenerate, and the unit ends up `failed`.
- **`pve-hosts-cert.service`**, a `oneshot` unit ordered **after `pve-cluster` and `pveproxy`**:
  `/etc/pve` is the `pmxcfs` filesystem and does not exist before `pve-cluster`. It is enabled in
  `multi-user.target`, so the check runs **at every boot** even if the hook changed nothing: it covers
  the first boot after installation, with an already misaligned certificate, and a new attempt after a
  failed run.

Why the hook does not call `pvecm` directly: at boot the hook runs at ~19.4 s, inside
`networking.service`, and `pve-cluster` starts at ~20.0 s, after `network.target`. `pvecm` would not find
`/etc/pve`. For the same reason the request is `--no-block`: a synchronous `systemctl start` would wait
for a unit ordered after the network that is waiting for it. With `--no-block` the job stays queued and
starts when `pve-cluster` and `pveproxy` are active; on a running node, for a live IP change, it starts
immediately.

**The rule is the certificate PVE would generate now.** PVE also puts `DNS:<hostname>.<domain>` in the
SAN, and takes the domain from the `search` (or `domain`) line of `/etc/resolv.conf`, not from
`/etc/hosts`. With `pve-hosts-domain` that line always carries the node domain, and the SAN FQDN is the
one set at installation. The script compares the SAN with what `pvecm updatecerts` would produce, not
with the FQDN in `/etc/hosts`: without the enter hook, a rule based on that FQDN would request a
regeneration at every run without ever obtaining it.

A change of the domain alone, with the same IP, does not change `/etc/hosts` and therefore the hook does
not request the unit: realignment happens at the next boot or with
`systemctl start pve-hosts-cert.service`.

## Parameters

At the top of the file:

| Variable | Value | Meaning |
|---|---|---|
| `PVEH_IFACE` | `vmbr0` | Interface the hook acts on |

`PVEH_IFACE` appears in `pve-hosts` and in `pve-hosts-domain`, and the two files must be kept aligned.
Hostname and domain are not parameters: the hostname is read from `/etc/hostname`, the domain from the
FQDN in `/etc/hosts` (§Node domain).

## Installing with `pmn`

The standard way from version `0.1.0` of the tool; `pmn` bootstrap in the main README.

```sh
pmn install dhcp-hook --dry-run    # plan and diff, no changes
pmn install dhcp-hook              # same plan, then a confirmation
pmn status dhcp-hook
```

`install` runs steps 2–5 of the manual installation: preconditions, FQDN check, the two hooks, the
certificate script and unit — enabled, not started —, removal of the legacy `dhclient.conf` block if
present, conversion of the `vmbr0` stanza. Files are installed **identical to the repository**: the
domain is not a parameter, the hooks read it from the FQDN in `/etc/hosts`. Every replaced file is backed
up first.

**By default the network change is not applied.** `install` writes `/etc/network/interfaces` and says to
run `ifreload -a` from the local console, or to reboot: applying it changes the IP and drops SSH
sessions. Then `systemctl start pve-hosts-cert.service`, as in step 6.

Preconditions, code `2` if missing: root, Proxmox VE 9, `ifupdown2`, `/usr/sbin/dhclient`, an
`iface vmbr0 inet` stanza in `/etc/network/interfaces`, no `/etc/network/interfaces.new` — network
changes pending in the GUI —, a `<hostname>.<domain>` FQDN in `/etc/hosts`.

`install` options:

| Option | Effect |
|---|---|
| `--domain <domain>` | only if `/etc/hosts` has no FQDN: adds it to the hostname line, with diff and confirmation. If the FQDN exists and differs, code `2`: fixing an existing FQDN stays manual |
| `--hook-only` | does not touch `/etc/network/interfaces` |
| `--apply-now` | runs `ifreload -a` and starts `pve-hosts-cert.service`, after a warning and a dedicated confirmation |

The conversion only changes the `iface vmbr0 inet static` stanza: `inet static` becomes `inet dhcp`,
`address`, `netmask` and `gateway` are removed, `bridge-*` and the rest of the file stay. A stanza that
is already `inet dhcp` is not touched; any other method gives code `2`.

`uninstall` options: `--restore-network` puts `/etc/network/interfaces` back to the last backup with a
static `vmbr0`, i.e. the one made by the conversion, with diff and confirmation, without applying it.
**The static IP in the backup may not be valid on the network the node is in now.** Without the option
the network stays on DHCP. The regenerated certificate stays; the copy of `pve-ssl.pem` made at
installation is in the backup.

`check`, called by `pmn status`: the four files identical to the repository, with mode and owner; the
unit enabled; no legacy `dhclient.conf` block; `vmbr0` on `inet dhcp`; the FQDN in `/etc/hosts`; a
single line for the hostname, with the current IP of `vmbr0`.

Sandbox test on macOS, 2026-09-26, with `PMN_SYSROOT` and a simulated `ip`: installation with and
without `--domain`, dry-run, reinstallation without changes, divergences detected by `check`, removal
with `--restore-network` also after a previous removal, `pmn update` with local changes and with
`--ref`. **Not tested on a node**: `systemctl`, `run-parts`, `ifreload` and `bootstrap.sh` do not run in
the sandbox.

## Manual installation

To be run **from the node's local console**: switching to DHCP changes the IP and an SSH session drops.

1. Keep the static configuration, needed for rollback:

   ```sh
   cp -a /etc/network/interfaces /etc/network/interfaces.static
   cp -a /etc/hosts /etc/hosts.static
   ```

2. In `/etc/network/interfaces` change **only the `vmbr0` stanza**: `inet static` becomes `inet dhcp`
   and `address` and `gateway` are removed. The rest of the file stays unchanged.

   ```
   auto vmbr0
   iface vmbr0 inet dhcp
           bridge-ports <nic>
           bridge-stp off
           bridge-fd 0
   ```

   `bridge-ports` is the one already in the file.

3. Check that `/etc/hosts` carries the node FQDN, from which the hooks derive the domain:

   ```sh
   grep -w "$(hostname)" /etc/hosts
   ```

   Expected: `<IP> <hostname>.<domain> <hostname>`. If the FQDN is missing or wrong, fix the line before
   going on.

4. Copy the two hooks, **without extension**, with mode `0644` and owner `root:root`:

   ```sh
   install -o root -g root -m 0644 pve-hosts /etc/dhcp/dhclient-exit-hooks.d/pve-hosts
   install -o root -g root -m 0755 -d /etc/dhcp/dhclient-enter-hooks.d
   install -o root -g root -m 0644 pve-hosts-domain /etc/dhcp/dhclient-enter-hooks.d/pve-hosts-domain
   ```

   Check syntax and pick-up by `run-parts`:

   ```sh
   sh -n /etc/dhcp/dhclient-exit-hooks.d/pve-hosts && sh -n /etc/dhcp/dhclient-enter-hooks.d/pve-hosts-domain && echo syntax-ok
   run-parts --list /etc/dhcp/dhclient-exit-hooks.d
   run-parts --list /etc/dhcp/dhclient-enter-hooks.d
   ```

   The first list must contain `pve-hosts` next to the existing hooks (for example `chrony`, `debug`,
   `resolved`, `rfc3442-classless-routes`), the second `pve-hosts-domain`. If it is missing, the file
   name is not compliant.

   On a node carrying the legacy `dhclient.conf` block, remove it:
   `sed -i '/^# BEGIN pve-hosts$/,/^# END pve-hosts$/d' /etc/dhcp/dhclient.conf`.

5. Install and enable the certificate script and unit:

   ```sh
   install -o root -g root -m 0755 pve-hosts-cert /usr/local/sbin/pve-hosts-cert
   install -o root -g root -m 0644 pve-hosts-cert.service /etc/systemd/system/pve-hosts-cert.service
   systemctl daemon-reload
   systemctl enable pve-hosts-cert.service
   ```

   `enable` without `--now`: the first run happens in step 6. Keep the current certificate for rollback:

   ```sh
   cp -a /etc/pve/local/pve-ssl.pem /root/pve-ssl.pem.before-pve-hosts-cert
   ```

6. Apply and align the certificate. `ifreload -a` may not renew an active lease if the `vmbr0`
   configuration does not change: on a node already on DHCP the domain is applied with the `STOP` and
   start cycle of test 2.

   ```sh
   ifreload -a
   systemctl start pve-hosts-cert.service
   ```

   Starting the unit explicitly is needed when the IP does not change but the domain does: the hook
   would not request it.

7. Check the result as in the runtime test (§Test procedures, verification steps), for the domain as in
   test 5 and for the certificate as in test 4.

## Test procedures

Tests 1–3 were passed on a PVE 9.2 node on 2026-09-26, **before** the certificate and search domain
were added; tests 4 and 5 have not been run yet. `<IP>` is an address of the test network.

### 1. Unit test

Checks the hook logic without touching the network.

```sh
cp -a /etc/hosts /root/hosts.before-test
# prepare /etc/hosts with a stale IP for the hostname and a duplicate line, then:
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    reason=REBOOT interface=vmbr0 new_ip_address=<IP> exit_status=0 \
    sh -c '. /etc/dhcp/dhclient-exit-hooks.d/pve-hosts'; echo "rc=$?"
cat /etc/hosts
stat -c '%a %U:%G inode=%i mtime=%Y' /etc/hosts
journalctl -t pve-hosts -n 5 --no-pager
```

Expected: a single `<IP> <FQDN> <hostname>` line right after `127.0.0.1`, with the FQDN the line had,
`0644 root:root`, `rc=0`, one log entry. Repeating the same command: no new log entry, **inode and mtime
unchanged** (no-op).

If `pve-hosts-cert.service` is installed, the first run — the one that changes `/etc/hosts` — requests
its start: with a fake IP the script regenerates the certificate with that IP. For a pure unit test, run
it before step 5 of the installation or with the node's real IP.

For the enter hook, the same scheme with `new_domain_name` printed after `source`:

```sh
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin reason=REBOOT interface=vmbr0 new_domain_name=other.lan \
    sh -c '. /etc/dhcp/dhclient-enter-hooks.d/pve-hosts-domain; echo "$new_domain_name"'
```

Expected: the domain of the FQDN in `/etc/hosts`, not `other.lan`; with `interface=eth9`, `other.lan`.

### 2. Runtime test

Checks the hook as actually invoked by `dhclient-script`. From the local console: `STOP` removes the IP
from the host.

```sh
dhclient -x -pf /run/dhclient.vmbr0.pid -lf /var/lib/dhcp/dhclient.vmbr0.leases vmbr0
ifreload -a
```

Verification steps:

```sh
ip -4 addr show vmbr0
journalctl -t pve-hosts -n 5 --no-pager      # expected reason=REBOOT
getent hosts "$(hostname)"
pvesh get /cluster/status
```

### 3. Reboot test

Checks boot order and adaptation to a new IP.

1. Change the node DHCP reservation on the test network server.
2. Make `/etc/hosts` deliberately stale (previous IP in the hostname line).
3. `reboot`.
4. Check:

   ```sh
   ip -4 addr show vmbr0; ip route; cat /etc/resolv.conf
   journalctl -b -t pve-hosts --no-pager       # expected reason=BOUND
   getent hosts "$(hostname)"
   pvesh get /cluster/status
   cat /etc/issue
   systemctl is-active pve-cluster pveproxy pvedaemon
   ```

Expected: new IP, correct route and DNS; `/etc/hosts`, `pvesh` and `/etc/issue` aligned with the new IP;
PVE services active.

### 4. Certificate test

To be run after step 5 of the installation.

1. Initial state:

   ```sh
   openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -ext subjectAltName -fingerprint -sha256
   getent ahosts "$(hostname)"
   ```

2. Direct run — regenerates if the SAN does not contain the resolved IP, otherwise does nothing:

   ```sh
   systemctl start pve-hosts-cert.service; systemctl status pve-hosts-cert.service --no-pager
   journalctl -t pve-hosts-cert -n 5 --no-pager
   openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -ext subjectAltName -fingerprint -sha256
   ```

   Expected: SAN with the current IP; if regenerated, a new fingerprint and an entry
   `certificate regenerated: IP <IP>, FQDN …`. A second run writes nothing to the log and leaves the
   fingerprint unchanged (no-op).

3. Reboot with IP change, as in test 3, then:

   ```sh
   journalctl -b -t pve-hosts -t pve-hosts-cert --no-pager
   systemctl status pve-hosts-cert.service --no-pager
   openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -ext subjectAltName
   echo | openssl s_client -connect localhost:8006 2>/dev/null | openssl x509 -noout -fingerprint -sha256
   ```

   Expected: the `pve-hosts` entry followed by the `pve-hosts-cert` one, SAN with the new IP, and the
   fingerprint presented on 8006 equal to the file's: `pveproxy` has been reloaded.

### 5. Search domain test

To be run after step 4 of the installation, from the local console, on a network whose DHCP does **not**
provide `domain-name` or provides a different one.

1. Lease renewal and content of `/etc/resolv.conf`:

   ```sh
   dhclient -x -pf /run/dhclient.vmbr0.pid -lf /var/lib/dhcp/dhclient.vmbr0.leases vmbr0
   ifreload -a
   cat /etc/resolv.conf
   grep -E 'domain-name|domain-search' /var/lib/dhcp/dhclient.vmbr0.leases | tail -n 4
   ```

   Expected: `domain <node domain>` and `search <node domain>` followed by any `domain-search` domains of
   the network; in the lease file, the `domain-name` received from the server (or none).

2. Certificate:

   ```sh
   systemctl start pve-hosts-cert.service
   journalctl -t pve-hosts-cert -n 5 --no-pager
   openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -subject -ext subjectAltName
   ```

   Expected: CN and SAN `DNS:` equal to the FQDN in `/etc/hosts`. If the certificate carried another
   FQDN, an entry `certificate regenerated: IP <IP>, FQDN <FQDN>`; otherwise no entry.

## Rollback

From the local console:

```sh
systemctl disable pve-hosts-cert.service
rm -f /etc/systemd/system/pve-hosts-cert.service /usr/local/sbin/pve-hosts-cert
systemctl daemon-reload
rm -f /etc/dhcp/dhclient-exit-hooks.d/pve-hosts /etc/dhcp/dhclient-enter-hooks.d/pve-hosts-domain
sed -i '/^# BEGIN pve-hosts$/,/^# END pve-hosts$/d' /etc/dhcp/dhclient.conf
cp -a /etc/network/interfaces.static /etc/network/interfaces
cp -a /etc/hosts.static /etc/hosts
ifreload -a
```

Without the copies from step 1 of the installation: restore by hand `inet static` in the `vmbr0` stanza
with `address <IP>/<prefix>` and `gateway <IP>`, and fix the hostname line in `/etc/hosts` with the same
IP. With the static network restored `dhclient` no longer runs on `vmbr0`, and the hooks would not be
invoked anyway: removing them avoids leaving orphan configuration. The `sed` on `dhclient.conf` removes
the legacy block if present; otherwise it does nothing.

The regenerated certificate stays valid after rollback. To get the previous one back:
`cp /root/pve-ssl.pem.before-pve-hosts-cert /etc/pve/local/pve-ssl.pem` and
`systemctl reload-or-restart pveproxy spiceproxy`. To get a new one with the restored static IP:
`pvecm updatecerts --force`, then the same `reload-or-restart`.

## Facts, inferences and known behaviour

### Reference environment (facts, 2026-09-26)

- `proxmox-ve 9.2.0`, `pve-manager 9.2.20`, kernel `7.0.14-19-pve`, Debian 13 (trixie).
- `ifupdown2 3.3.0-1+pmx12`. The addon `/usr/share/ifupdown2/addons/dhcp.py` invokes `dhclient`
  (`isc-dhcp-client 4.4.3-P1-8`, marked deprecated in Debian 13). `dhcpcd-base` is installed but not
  used by `ifupdown2`. `systemd-networkd` and NetworkManager inactive.
- Lease in `/var/lib/dhcp/dhclient.vmbr0.leases`, pidfile `/run/dhclient.vmbr0.pid`.
- `/usr/sbin/dhclient-script`, function `run_hook` (line 148), runs the hooks with `source`. Available
  variables: `$reason`, `$interface`, `$new_ip_address`, `$old_ip_address`, `$exit_status`.

### Established behaviour (facts)

- **AppArmor.** Profile `/etc/apparmor.d/usr.sbin.dhclient`. `dhclient-script` runs unconfined
  (`Uxr`), so the hook is not subject to AppArmor. The kernel logs denials
  `apparmor="DENIED" operation="create" family="unix"` on the `dhclient` process, which still obtains
  the lease.
- **DNS.** `dhclient-script` applies IP, netmask, gateway and DNS directly and rewrites
  `/etc/resolv.conf` (there is no `resolvconf` nor systemd-resolved). Without `pve-hosts-domain`, if
  DHCP does not provide `domain-name` the `search` line disappears.
- **PVE services.** The IP in `pvesh get /cluster/status` is resolved from the hostname at every call:
  after fixing `/etc/hosts` it is updated without restarting `pve-cluster`, `pveproxy` or `pvedaemon`.
  `pveproxy` (8006) and `spiceproxy` (3128) listen on `*`: the IP change requires no restart.
- **Banner.** `pvebanner.service` (`DefaultDependencies=no`, `After=local-fs.target`) regenerates
  `/etc/issue` at boot **before** the network is up — measured: pvebanner at 9.78 s, lease at 19.36 s.
  The banner is correct only because the hook calls `pvebanner`.
- **Boot order**, measured: `pve-hosts` hook at 19.36 s → end of `networking.service` at 20.02 s →
  start of `pve-cluster` at 20.04 s. `/etc/hosts` is therefore updated before `pmxcfs` starts.
- **Certificate.** Without `pve-hosts-cert`, the SAN of `/etc/pve/local/pve-ssl.pem` contains the IP of
  the original installation and is not updated.
- **Firewall.** `pve-firewall localnet` detects the new subnet after the IP change (firewall disabled on
  the test node).

### PVE behaviour read in the source (facts, not tested on a node)

From the `pve-cluster` and `pve-manager` source, `master` branch of the Proxmox GitHub mirror, read on
2026-09-26; the reference environment uses `pve-manager 9.2.20`, and correspondence with that version is
not verified.

- `pvecm updatecerts --force` calls `updatecerts_and_ssh`, which generates the node's missing files,
  regenerates `pve-ssl.pem` with the existing key `pve-ssl.key`, signing it with `pve-root-ca`, and
  realigns the node's SSH keys and `known_hosts`. The CA does not change. It waits at most 80 s for
  `pmxcfs` to be mounted and quorate.
- **The SAN IP** comes from `remote_node_ip`: on a node without cluster, resolution of the hostname with
  `getaddrinfo`, first non-loopback address — so from `/etc/hosts`, aligned by the hook.
- **The SAN FQDN and the CN** are `<hostname>.<search>`, where `<search>` is the first domain of the last
  `search` or `domain` line of `/etc/resolv.conf`; without that line, only `DNS:<hostname>` and a CN
  equal to the short hostname.
- `pveproxy.service` runs `ExecStartPre=-/usr/bin/pvecm updatecerts --silent`, without `--force`, and is
  ordered after `pve-cluster.service`; `ExecReload` of `pveproxy` and `spiceproxy` is `restart`, the
  daemon's internal restart. `pve-cluster.service` is ordered after `network.target`.

### `dhclient` behaviour read in the source (facts, not tested on a node)

Read on 2026-09-26 in the main branches, not in the reference versions (`isc-dhcp-client 4.4.3-P1-8`,
`ifupdown2 3.3.0-1+pmx12`): correspondence is not verified.

- `make_resolv_conf` in `dhclient-script` (`debian/dhclient-script.linux`, `master` branch of the Debian
  `isc-dhcp` repository): with `domain-name` it writes `domain <first domain>`; with `domain-search` it
  writes `search <domain-search>`, preceded by `domain-name` if not already there; with `domain-name`
  only it writes `search <domain-name>`.
- The same script sources the hooks in `/etc/dhcp/dhclient-enter-hooks.d` before the `case` on
  `$reason`, hence before `make_resolv_conf`, which reads `$new_domain_name`: the value assigned by
  `pve-hosts-domain` is the one written to `/etc/resolv.conf`.
- `run_hook` declares `local exit_status=0` before `source`: inside exit hooks `$exit_status` is always
  `0`, and the `pve-hosts` condition on it filters nothing. Harmless, not fixed.
- Sandbox check on macOS, `dash`, with the `make_resolv_conf` function extracted from that source and
  paths replaced, 2026-09-26: with FQDN `<hostname>.site.example.net` in `/etc/hosts`, `domain` and the
  first `search` are `site.example.net` both without `domain-name` from DHCP and with a different
  `domain-name`, and the `domain-search` domains of the host network follow; on another interface the
  DHCP `domain-name` applies; a multi-level FQDN or one with a trailing dot gives the whole right-hand
  part, without the dot; without FQDN the `/etc/hosts` line stays `<IP> <hostname>`; a hostname that is
  a prefix of another (`node1`, `node1x`) is not confused.

### Inferences (not verified)

- At boot on a different network, or with a different reservation, the switch from `REBOOT` to `BOUND`
  is due to the server NAK on the INIT-REBOOT request for the old IP, followed by DISCOVER; it would
  explain about 10 s of wait for the lease. Estimated probability ~80%.
- The absence of `DHCPREQUEST`/`DHCPACK` messages from the journal is due to the AppArmor denials on unix
  socket creation: `dhclient` would fail to write to `/dev/log`. ~75%.
- With `pve-firewall` enabled, `local_network` is recomputed at every cycle without restart. ~70%.
- `spiceproxy` presents `pve-ssl.pem` even when a custom `pveproxy-ssl.pem` exists; for this reason the
  script also reloads `spiceproxy`, which is harmless if it does not. ~70%.

### Known limits

- Destination network **without DHCP**: with `reason=TIMEOUT` `dhclient-script` reuses the old lease
  only if the old gateway answers ping; otherwise the node stays without IP. Open point.
- **Search domain**: if the `domain-search` of the host network already contains the node domain but not
  in first position, `dhclient-script` does not move it to the head, and PVE would use the first domain
  in the list. Not a realistic case for customer networks, not handled.
- **Every regeneration changes the certificate fingerprint**: at every move with an IP change the
  browser asks for the exception again, and a client that stored the node fingerprint — for example a
  Proxmox Datacenter Manager remote or an API integration — must be updated.
