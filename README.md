# ss-easy

Turnkey [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)
installer and manager for Linux servers — a single pure-bash tool that installs
the proxy, manages users, and hands you ready-to-import `ss://` links.

One command sets up a hardened, systemd-managed Shadowsocks server with a
dedicated unprivileged service user, sane firewall rules, BBR, and a first user.
Everything after that — adding/removing users, viewing links and QR codes — is a
single subcommand or an interactive menu.

## What it does

- Installs the pinned, checksum-verified `ssserver` binary (musl static build).
- Generates `/etc/ss-easy/config.json` from a single source-of-truth registry
  (`/etc/ss-easy/users.json`); every change regenerates the config and reloads
  the service.
- Manages users: `user add`, `user del`, `user list`, `user show` — each with a
  crypto-random secret, an auto-allocated high port, an `ss://` link, and a
  terminal QR code.
- Hardened systemd unit (`NoNewPrivileges`, `ProtectSystem=strict`, read-only
  config bind), runs as a dedicated non-root user.
- Opens only the user's port in the firewall (ufw or firewalld); never touches
  your SSH rule.
- Auto-detects the public IP across several HTTPS sources (with confirmation in
  interactive mode), and enables BBR.
- Clean `uninstall` that removes everything ss-easy installed and leaves the rest
  of the box (and SSH) untouched.

## Quick start

`ss-easy` ships as a single self-contained bundle, pinned to a release tag and
published with a SHA256 checksum. The bootstrap downloads that tagged bundle,
**verifies its checksum before executing it**, installs it to
`/usr/local/bin/ss-easy`, and runs the installer.

Replace `<tag>` with the release you want (e.g. `v1.0.0`):

```sh
curl -fsSL https://raw.githubusercontent.com/youruser/ss-easy/<tag>/install.sh | sudo bash
```

Pass installer flags after `bash -s --` (e.g. fully unattended install):

```sh
curl -fsSL https://raw.githubusercontent.com/youruser/ss-easy/<tag>/install.sh | sudo bash -s -- --silent
```

The bootstrap uses a hardened `curl` (`--fail --proto '=https' --tlsv1.2`, no
`-k`) and aborts without installing anything if the download fails or the
checksum does not match.

### Git-clone alternative

If you prefer to inspect the source first (recommended for `curl | bash` of any
root script):

```sh
git clone https://github.com/youruser/ss-easy.git
cd ss-easy
git checkout <tag>

# Option A: run the bootstrap from the clone (same verify-then-install path):
sudo bash install.sh --silent

# Option B: build and run the bundle directly (skips the download + checksum):
bash build.sh
sudo ./dist/ss-easy install --silent
```

### Manually verifying the checksum

The bootstrap verifies automatically; to check by hand before trusting it:

```sh
tag=<tag>
base="https://raw.githubusercontent.com/youruser/ss-easy/$tag"
curl -fsSL "$base/dist/ss-easy"               -o ss-easy
curl -fsSL "$base/checksums/bootstrap.sha256" -o bootstrap.sha256
sha256sum -c bootstrap.sha256        # must print: ss-easy: OK
```

> **Note on the checksum:** the build is **not** byte-reproducible, so the hash
> in `checksums/bootstrap.sha256` is valid only for the exact `dist/ss-easy`
> artifact published for a given tag. It is regenerated and committed by the
> release pipeline on every version bump:
>
> ```sh
> sha256sum dist/ss-easy | sed 's#dist/##' > checksums/bootstrap.sha256
> ```
>
> A local `bash build.sh` will produce a different hash; the published value is
> the canonical one the bootstrap checks against.

## Usage

```sh
ss-easy                       # interactive menu (whiptail)
ss-easy install [--silent]    # install + first user
ss-easy user add alice        # add a user, print its ss:// link + QR
ss-easy user list             # list users (no secrets)
ss-easy user show alice       # connection details + ss:// link for one user
ss-easy user del alice        # remove a user
ss-easy status                # service status
ss-easy uninstall             # remove everything ss-easy installed
```

Run `ss-easy --help` for the full command list.

## Supported distros and architectures

**Distributions** (systemd required):

- Debian / Ubuntu (apt family)
- CentOS / Rocky Linux / AlmaLinux (dnf/yum family)

**Architectures:** `x86_64` and `aarch64` (the pinned musl static ssserver build
ships for both). Other architectures are rejected with a clear error.

ss-easy manages a real systemd service, so it must run on a normal VPS/host with
systemd as the init system — not inside a minimal container without an init.

## Cipher notes

The default cipher is **`2022-blake3-aes-256-gcm`** (Shadowsocks AEAD-2022, the
modern SIP022 scheme). It is the strongest, recommended choice and what you
should use unless a specific client cannot speak it.

SIP022 links are structurally different from classic links: the userinfo is the
literal `method:key` (the key is a 32-byte value in standard base64), not a
base64-encoded password. ss-easy emits the correct format per cipher
automatically.

If you have an older client that does not support the 2022 ciphers, use the
classic fallback **`chacha20-ietf-poly1305`** (SIP002), which is widely
supported:

```sh
ss-easy user add legacy --method chacha20-ietf-poly1305
```

| Cipher | Scheme | When to use |
|-|-|-|
| `2022-blake3-aes-256-gcm` (default) | SIP022 / AEAD-2022 | Default; modern clients |
| `chacha20-ietf-poly1305` | SIP002 / classic AEAD | Older clients without 2022 support |

### Client requirements

To import the generated `ss://` link or scan its QR code:

- **2022-blake3 (default):** a current Shadowsocks client that supports
  AEAD-2022 / SIP022 — e.g. Shadowrocket (iOS), v2rayN (Windows), Clash Meta /
  Mihomo, sing-box, the official shadowsocks-rust client, or a recent
  shadowsocks-android. Older clients will silently fail on a 2022 link.
- **chacha20-ietf-poly1305 (fallback):** virtually any modern Shadowsocks client,
  including older ones that predate AEAD-2022.

## Security note: `curl | bash`

Piping any script to `bash` as root is a trust decision. ss-easy reduces the risk
with tag pinning plus a published SHA256 that the bootstrap verifies **before**
executing the bundle (so a swapped release asset, a moved branch, or a corrupted
download is rejected, not run). TLS protects the transport; the checksum protects
integrity. If you would rather not trust the pipe at all, use the **git-clone
alternative** above and read the source first — it is plain bash with no
dependencies beyond `curl`, `jq`, and standard tools.

## License

See the repository for license details.
