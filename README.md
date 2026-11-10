# Devbox KiCad — Hardware Dev Container for Coolify

Fork of [code-server-cpu](https://github.com/cpietsch/code-server-cpu) with a headless KiCad 9 toolchain, so Claude Code can design, check and export PCBs end to end.

A Tailscale-accessible dev container running on your Coolify host, with Python, Node, Docker CLI (against an isolated DinD daemon), an SSH server for Cursor/VS Code Remote, and the usual tools (git, gh, uv, pnpm, ripgrep, zsh, tmux).

## Architecture

```
Laptop ──tailnet──► tailscale container ◄── shared netns ──► dev container (sshd)
                     (NET_ADMIN, tun)                              │
                                                                   │ TCP+TLS
                                                                   ▼  localhost:2376
                                                             dind container
                                                             (privileged, isolated)
                                                                   │
                                                             devbox-kicad-dind-data
                                                             (own images/containers)
```

Key design decisions:

- **No port publishing on the host.** The SSH port is only reachable through the tailnet. No attack surface on the public IP.
- **Tailscale as a sidecar**, not baked into the dev image. Clean lifecycle (Tailscale update ≠ image rebuild), and the dev container needs no NET_ADMIN capabilities.
- **Docker-in-Docker as a sidecar.** An isolated, dedicated daemon. The dev container talks to it via TCP+TLS (`localhost:2376` via the shared network namespace) and has *no* access to the host Docker or Coolify. The trade-off: `dind` runs with `privileged: true`, but that privilege stays in its own namespace — cleanly separated from the host Coolify Docker.
- **Claude Code is not baked into the image.** Install it after first login with `npm i -g @anthropic-ai/claude-code`. Updates are then `npm update -g` instead of an image rebuild.

## Deployment in Coolify

1. Create a Git repo with `Dockerfile`, `sshd_dev.conf`, `entrypoint.sh`, and `docker-compose.yml` (exactly the files from this folder).
2. In Coolify: **Project → + New Resource → Docker Compose Empty** (or "Application" → "Docker Compose" if building from Git).
3. Paste the Compose file or connect the Git repo.
4. Set the following **Environment Variables** in the Coolify UI:

   | Variable | Example / Notes |
   |---|---|
   | `TS_AUTHKEY` | `tskey-auth-...` from https://login.tailscale.com/admin/settings/keys. Recommended: *Reusable*, do NOT set *Ephemeral* (you want to keep the host), enable *Pre-approved* if you use device approval. |
   | `INSTALL_KICAD_3D` | optional, `true` to include KiCad 3D models (~6 GB) |
   | `TS_HOSTNAME` | `devbox-kicad` (or whatever you want to appear in your tailnet) |
   | `SSH_AUTHORIZED_KEYS` | Your public keys, one per line. Contents of `~/.ssh/id_ed25519.pub` |

5. Deploy. On first start Coolify builds the image, both containers come up, and Tailscale registers the device.

## Initial Setup After First Deploy

### Find your tailnet hostname

Your [Tailscale admin panel](https://login.tailscale.com/admin/machines) will show a device named `devbox-kicad`. Note down the MagicDNS name (e.g. `devbox-kicad.tail-scales.ts.net`).

### Test the SSH connection

On your laptop (Tailscale must also be running there):

```bash
ssh dev@devbox           # MagicDNS is enough if enabled
# or
ssh dev@devbox.<tailnet>.ts.net
```

On first connect you confirm the host key (it is persisted in the `devbox-kicad-sshhostkeys` volume, so it survives rebuilds).

### `~/.ssh/config` on your laptop

```ssh-config
Host devbox
    HostName devbox.<tailnet>.ts.net
    User dev
    ForwardAgent yes
    ServerAliveInterval 30
```

After that, in Cursor/VS Code: **Remote-SSH: Connect to Host... → devbox**.

### Install Claude Code

After SSH-ing in:

```bash
npm i -g @anthropic-ai/claude-code
claude --version
claude   # first login with your Anthropic account
```

Authentication runs interactively via an OAuth flow in the browser. Since you are using SSH, `claude` prints a URL that you open on your laptop.

### Workspace

Your code goes in `/home/dev/workspace` — it lives on its own Docker volume and survives rebuilds and updates. Example:

```bash
cd ~/workspace
gh auth login          # once
gh repo clone me/project
cd project
uv venv && source .venv/bin/activate    # for Python
pnpm install                             # for Node
```

## PCB Toolchain

Everything runs headless; no display or GPU needed.

| Tool | What for |
|---|---|
| `kicad-cli` (KiCad 9, Ubuntu universe) | ERC, DRC, Gerber/BOM/STEP/SVG export, 3D render |
| `eda-python` | Python with `pcbnew`, `kikit`, `build123d` (enclosure CAD) |
| `kikit` | JLCPCB/PCBWay fab outputs, panelization |
| `pcb-check` | The verify loop: ERC + DRC (with schematic parity) + PNGs of every layer and the schematic in `out/check/`. `--render` adds 3D renders, `--fab` writes JLC gerbers/BOM/CPL |
| `xvfb-run`, `rsvg-convert`, `pdftoppm` | Offscreen rendering and SVG/PDF → PNG so Claude can look at its own work |

Start a hardware project:

```bash
cd ~/workspace && mkdir myboard && cd myboard && git init
cp /opt/kicad-templates/CLAUDE.md .     # fill in the TODOs
claude
```

The `CLAUDE.md` template tells Claude Code to run `pcb-check` after every change and not to call a step done while it fails.

Notes:
- **Python venvs:** `pcbnew` is a system module. Use `eda-python`, or create venvs with `uv venv --system-site-packages` / `python3 -m venv --system-site-packages`.
- **3D models** (~6 GB) are off by default. Set `INSTALL_KICAD_3D=true` in Coolify and rebuild if you need STEP exports with component bodies for enclosure fit checks.
- **Library tables** are seeded into `~/.config/kicad/9.0/` on first start; your edits there persist.
- **Reviewing in the GUI:** push the project and open it in KiCad on your laptop.

## Docker Access

The dev container talks to the DinD daemon — **not** the Coolify host. This is a clean separation: containers you start here are invisible to Coolify and cannot accidentally break your production setup.

```bash
docker info        # shows the dind daemon, not the host
docker ps          # only containers YOU started in dind
docker run --rm hello-world
```

The TLS client certificates for the handshake are mounted read-only at `/certs/client/`. `DOCKER_HOST`, `DOCKER_TLS_VERIFY`, and `DOCKER_CERT_PATH` are automatically exported into interactive shells — no configuration needed.

**Where are my images?** In the `devbox-kicad-dind-data` volume. They survive dev container rebuilds and restarts, and are only gone if you explicitly delete the volume.

**If you need the host Docker** (e.g. to tail a Coolify container log): `docker -H unix:///var/run/docker.sock …` won't work — the socket is intentionally not mounted. For those cases, SSH directly to the host or use the Coolify UI.

## Resources

The image is ~2–3 GB larger than the base devbox because of KiCad (~8 GB more with 3D models). RAM at idle is unchanged (~1–2 GB); 3D renders and large DRC runs briefly use 1–2 GB more. On a 12 GB / 6-core host there is plenty left for Coolify and deployments. If you want, add resource limits to the `dev` service in the Compose file:

```yaml
    deploy:
      resources:
        limits:
          cpus: "4"
          memory: 8g
```

## Updates

- **Update Node/Python/tools**: trigger a redeploy in Coolify (rebuild image). Workspace and home volumes are preserved.
- **Update Tailscale**: redeploy only the `tailscale` service; the dev container stays live.
- **Update Claude Code**: `npm update -g @anthropic-ai/claude-code` inside an SSH session.

## Troubleshooting

- **SSH not working**: check the Coolify logs for the `dev` service to confirm `sshd` is running. Check the `tailscale` service to confirm it authenticated (`tailscale status`).
- **Coolify stays on "unknown"**: every service needs a healthcheck or Coolify will not mark the stack healthy. `dev` checks `pgrep -x sshd`. It can stay `starting` for up to 90s while the entrypoint waits for DinD certs.
- **`docker: Cannot connect to the Docker daemon`**: DinD is still starting up or the certs have not been written yet. Check `docker compose logs dind` in Coolify. After a reboot it takes a few seconds for the daemon to become ready.
- **`docker: tls: failed to verify certificate`**: The cert volume (`devbox-kicad-dind-certs`) was manually cleared or is inconsistent between the dind and dev containers. Restart both containers so dind generates fresh certs that the dev container can pick up.
- **Host key warning on laptop after rebuild**: should not happen with the host-key volume. If it does: `ssh-keygen -R devbox` on the laptop, then reconnect once.
- **Tailscale container restarting in a loop**: usually an expired or invalid `TS_AUTHKEY`. Generate a new key, update the env var, redeploy.
- **DinD volume too large**: `docker system prune -a` inside the dev container cleans up the DinD daemon and leaves the host Docker untouched.
