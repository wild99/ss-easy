# ss-easy

Turnkey installer and manager for a [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)
server. One command sets up a working server, prints a ready-to-use `ss://` link
and QR code, and gives you a friendly menu (TUI) plus a scriptable CLI to manage
users and the service — no Linux expertise required.

- **One-command install** (interactive or fully silent/unattended)
- **Per-user access** — each user gets their own port, password/key, `ss://` link and QR
- **CLI** for automation and **whiptail TUI** for click-through management
- **Modern crypto** — `2022-blake3-aes-256-gcm` by default, `chacha20-ietf-poly1305` fallback
- **Hardened by default** — checksum-verified binary, firewall auto-config (your SSH stays open), BBR, non-root service, strict file permissions
- **Debian/Ubuntu + RHEL family (CentOS/Rocky/Alma)**, `amd64` and `arm64`

> ⚠️ Requires a Linux server with **systemd** and **root** access. Intended for VPS hosts.

---

## Install

### Quick start (one-liner)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/wild99/ss-easy/v1.0.3/install.sh)"
```

This downloads the version-pinned, **SHA256-verified** bundle, installs the
dependencies and the shadowsocks-rust binary, creates your first user, opens the
firewall, enables BBR, starts the service, and prints the connection link + QR.

> **Why not `curl … | sudo bash`?** Piping the script *into* `sudo` leaves `sudo`'s
> stdin attached to the pipe, not your keyboard. On distros where `sudo` uses a
> pseudo-terminal (e.g. Ubuntu 24.04's default `use_pty`), the interactive dialogs
> can't read arrow keys — they leak as `^[[` escape codes. Running the script as a
> `sudo bash -c "$(…)"` argument (or the two-step below) keeps the terminal attached.
> Already root? Drop the `sudo`. Want a non-interactive install? Use `--silent` (below).

### Silent / unattended install

Silent mode asks nothing and uses safe defaults (random high port, crypto-random
secret, auto-detected public IP). It needs no terminal, so a plain pipe is fine:

```bash
curl -fsSL https://raw.githubusercontent.com/wild99/ss-easy/v1.0.3/install.sh | sudo bash -s -- --silent
```

Override any default (two-step keeps flags readable):

```bash
curl -fsSL https://raw.githubusercontent.com/wild99/ss-easy/v1.0.3/install.sh -o ss-easy-install.sh
sudo bash ss-easy-install.sh --silent --port 8443 --method chacha20-ietf-poly1305 --name alice
```

### Alternative: clone and review first (recommended for the cautious)

```bash
git clone https://github.com/wild99/ss-easy.git
cd ss-easy
sudo ./ss-easy install
```

### Verify the download manually (optional)

The bundle's checksum is committed next to it and re-verified in CI:

```bash
tag=v1.0.3
base="https://raw.githubusercontent.com/wild99/ss-easy/$tag"
curl -fsSL "$base/dist/ss-easy" -o ss-easy
curl -fsSL "$base/checksums/bootstrap.sha256" | sed "s#dist/##" | sha256sum -c -
```

---

## Usage

After install, `ss-easy` lives at `/usr/local/bin/ss-easy`.

### TUI (easiest)

```bash
sudo ss-easy            # or: sudo ss-easy tui
```

A menu lets you manage the service, add/remove users, view connection links + QR
codes, see server info, and uninstall — without typing any commands.

### Manage users (CLI)

```bash
sudo ss-easy user add alice      # create a user → prints ss:// link + QR, saves an access file
sudo ss-easy user list           # list users (name, port, method)
sudo ss-easy user show alice     # reprint a user's ss:// link + QR
sudo ss-easy user del alice      # remove a user (closes its port)
```

Each user's access details are also saved to `/etc/ss-easy/users/<name>.txt`.

### Manage the service (CLI)

```bash
sudo ss-easy status
sudo ss-easy start | stop | restart
sudo ss-easy enable | disable     # start on boot (or not)
```

### Uninstall

```bash
sudo ss-easy uninstall            # removes service, config, users, binary and the firewall rules it added
```

`--silent`/`--yes` skips the confirmation prompt. Your SSH rule is never touched.

---

## Connecting a client

Use the printed `ss://` link or scan the QR code in any shadowsocks client
(Outline, Shadowrocket, v2rayN, Clash, etc.).

**Cipher compatibility:** the default `2022-blake3-aes-256-gcm` (SIP022) requires
a reasonably recent client. If your client is older, create the user with the
classic fallback:

```bash
sudo ss-easy user add bob --method chacha20-ietf-poly1305
```

---

## What it sets up

| Item | Location / detail |
|-|-|
| CLI/TUI command | `/usr/local/bin/ss-easy` |
| User registry (source of truth) | `/etc/ss-easy/users.json` (`0600`) |
| shadowsocks-rust config (generated) | `/etc/ss-easy/config.json` (`0600`) |
| Per-user access files | `/etc/ss-easy/users/<name>.txt` (`0600`) |
| systemd unit | `ss-easy.service` (runs as a dedicated unprivileged user) |
| Proxy binary | `/usr/local/bin/ssserver` (checksum-verified) |

All state lives under `/etc/ss-easy` (`0700`). The CLI and TUI share one source of
truth, so they never disagree.

---

## Security notes

- **`curl | bash` runs code as root.** The code is open and readable — review it,
  or use the `git clone` flow. The shadowsocks-rust binary is pinned to a known
  release and verified against a committed SHA256 before install; the bootstrap
  bundle is likewise verified before it executes.
- **Your firewall/SSH is safe.** ss-easy only adds/removes rules for its own user
  ports (ufw/firewalld). It never modifies your SSH rule and never enables a
  firewall from scratch without consent.
- **Secrets** are generated from a cryptographic source and stored with strict
  permissions; they are never written to logs.
- **The proxy does not run as root** — it runs under a dedicated unprivileged
  system user with systemd hardening.

---

## Supported systems

- **OS:** Debian/Ubuntu (`apt`), CentOS/Rocky/Alma (`dnf`/`yum`). Requires systemd.
- **Arch:** `amd64` (x86_64) and `arm64` (aarch64).
- **Runtime deps** (installed automatically): `whiptail` (RHEL: `newt`), `qrencode`, `jq`, `curl`.

---

## Development

Pure Bash, organized as `lib/*.sh` modules bundled by `build.sh` into the single
distributable `dist/ss-easy`.

```bash
bash build.sh                 # assemble dist/ss-easy
shellcheck ss-easy lib/*.sh   # lint
bats tests/                   # unit tests
```

CI runs shellcheck, the bats suite, a deterministic-build/checksum gate, and real
Docker integration on Debian + Rocky (full lifecycle + end-to-end proxy smoke for
both ciphers).

---

## License

[MIT](LICENSE)
