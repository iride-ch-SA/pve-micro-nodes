# pve-micro-nodes

Tools for iride.ch SA **Proxmox VE micro-nodes**: mini-PCs running Proxmox VE as a single node — no
cluster, no HA, no Ceph — dedicated to running a single Windows VM.

## The model

A micro-node has a two-stage life cycle: **preparation** at iride.ch, then **relocation to the
destination network**, where the host gets its address via DHCP, usually followed by a reservation on
the local firewall. A node may be moved several times, including changes of subnet, gateway and DNS,
and must adapt to each move by itself, without console access.

One constraint stays fixed: the **FQDN does not change** — `<hostname>.<domain>`, set at installation
time — whatever domain the DHCP server of the host network provides. The tools carry no domain in their
code: they derive it from the node's FQDN.

Proxmox VE is not designed for this life cycle: the installer writes a static network configuration and
assumes that the node identity never changes. The tools in this repository close, one by one, the gaps
between that assumption and real operation. The reasons behind the architecture — one PVE node per VM —
are out of scope.

## Tools

| Tool | Problem | Status |
|---|---|---|
| [`dhcp-hook`](dhcp-hook/README.md) | PVE requires the hostname to resolve, via `/etc/hosts`, to the node's real IP; no component updates `/etc/hosts` when DHCP assigns a new IP, nor the SAN of the node certificate; the domain in `/etc/resolv.conf` follows the DHCP server of the host network | Hook tested on a PVE 9.2 node, 2026-09-26; certificate regeneration and FQDN-derived domain not yet tested on a node |

## Installing on a node: `pmn`

Tools are installed with **`pmn`**, from the repository clone in `/opt/pve-micro-nodes`, available as
`/usr/local/sbin/pmn`. Each tool installs, checks and uninstalls itself; the manual installation
described in each tool's README remains valid.

### Bootstrap

As root, on the node:

```sh
curl -fsSLo /tmp/pmn-bootstrap.sh https://raw.githubusercontent.com/iride-ch-SA/pve-micro-nodes/main/bootstrap.sh
bash /tmp/pmn-bootstrap.sh
```

`bootstrap.sh` checks for root and `pveversion`, installs `git` only if missing — an `apt-get update`
that fails because of the `pve-enterprise` repository without a subscription is tolerated, and the APT
configuration is left untouched —, clones the repository into `/opt/pve-micro-nodes`, checks out the
latest `vX.Y.Z` tag and creates the symlink. If `/opt/pve-micro-nodes` is already a clone, it does not
clone again and points to `pmn update`. Options: `--repo <url>` (or `PMN_REPO_URL`) for a different
repository, `--ref <tag|branch>`.

Manual equivalent:

```sh
apt-get install -y git
git clone https://github.com/iride-ch-SA/pve-micro-nodes.git /opt/pve-micro-nodes
git -C /opt/pve-micro-nodes checkout --detach "$(git -C /opt/pve-micro-nodes tag -l 'v*' --sort=-v:refname | head -n1)"
ln -sfn /opt/pve-micro-nodes/pmn /usr/local/sbin/pmn
```

### Commands

| Command | Function |
|---|---|
| `pmn update [--ref <tag\|branch>]` | `git fetch --tags` and checkout of the latest tag, or of the given ref; stops if the clone has local changes |
| `pmn list` | available tools: name, version, description |
| `pmn status [<tool>]` | result of `check` and data recorded at installation |
| `pmn install <tool> [--dry-run] [--yes] [options]` | installation, with diff and confirmation |
| `pmn uninstall <tool> [--dry-run] [--yes] [options]` | removal, with backup |
| `pmn version` | ref and commit of the clone |

Options that `pmn` does not recognise are passed to the tool script. Every action is logged to the
journal with tag `pmn`; backups go to `/var/backups/pve-micro-nodes/<date>-<tool>/`, keeping the
original path; installation state goes to `/var/lib/pve-micro-nodes/installed/<tool>`. Without a
terminal, confirmations are given with `--yes`, otherwise the operation is cancelled (code `3`).

### Tool contract

A tool is a sub-folder with `tool.conf` and three executables: `install`, `uninstall`, `check`.

- `tool.conf`, read with `source`: `TOOL_NAME`, `TOOL_VERSION`, `TOOL_DESCRIPTION`, optional
  `TOOL_REQUIRES_PVE` (major version, for example `9`).
- Variables passed by `pmn`: `PMN_ROOT`, `PMN_TOOL_DIR`, `PMN_DRY_RUN` and `PMN_YES` (`0`/`1`),
  `PMN_BACKUP_DIR`, `PMN_BACKUP_BASE`, `PMN_STATE_FILE`. Shared functions are in `lib/common.sh`.
- Exit codes of `install` and `uninstall`: `0` done or nothing to do, `1` error, `2` precondition not
  met, `3` cancelled. Exit codes of `check`: `0` installed and consistent, `1` not installed, `2`
  installed but diverging, with a summary on stdout.
- `PMN_SYSROOT` prefixes a root to system paths: it is only meant for sandbox tests.

### Test procedure on a node

From the local console, on a node whose DHCP reservation can be changed:

1. bootstrap, as above — a test node can read from another repository with `--repo`;
2. `pmn list` and `pmn status`: `dhcp-hook` not installed, code `1`;
3. `pmn install dhcp-hook --dry-run`: diff of `/etc/network/interfaces` and new files, no changes;
4. `pmn install dhcp-hook`, confirm, then `ifreload -a` or reboot;
5. `pmn status`: all lines `ok`, consistent result;
6. change the DHCP reservation and `reboot`;
7. `pmn status`: `/etc/hosts` aligned with the new IP of `vmbr0`; then tests 3–5 of the `dhcp-hook`
   README;
8. `pmn uninstall dhcp-hook`, or with `--restore-network`, and `pmn status`: not installed.

## Development and distribution

This repository is the **public distribution** used by nodes in operation, including outside the
iride.ch network, and is the default of `bootstrap.sh`. It receives **only release trees**: one
`Release vX.Y.Z` commit per tag, without the development history. Development, issues and reviews
happen in an internal repository. `pmn update --ref <branch>` moves a node to a branch other than the
latest release.

## Conventions

- **One tool, one sub-folder** at the root, with its own `README.md` covering purpose, requirements,
  logic, installation, tests and rollback. This file lists the tools and does not repeat their content.
- **English** for documentation, code comments and script output.
- **Facts and inferences kept apart.** In the READMEs, what has been measured or tested is written as a
  fact, with its date; what is deduced is declared as an inference, with a probability estimate.
- **The git file mode is part of the contract**: a file read with `source` is recorded as `100644`, an
  executable as `100755`. The tool README states how it must be installed.
- **Versions**: semantic tags `vX.Y.Z` on the repository; each tool's `TOOL_VERSION` follows its own
  changes. `pmn update` without arguments moves the node to the latest tag.
- **Quality**: `shellcheck -x` with no findings on every script, run from the repository root; hooks
  with `-s sh`.
- **The repository does not act on nodes.** It holds material and procedures; installation on a node is
  carried out by iride.ch staff, following the tool README.
- **Confidentiality**: no reference to real or test nodes — hostnames, domains, customer codes, hardware
  models, IP or MAC addresses, network data — in documentation, comments or examples. Placeholders only:
  `<hostname>`, `<domain>`, `<IP>`.

No license is granted: proprietary material of iride.ch SA, all rights reserved.
