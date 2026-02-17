# CLAUDE.md — Loom Development Notes

## VM Testing Workflow

Build, launch, test, reset cycle for the first-boot kiosk experience:

1. **Build**: `nix build .#vm`
   - Stage changes first (`git add`) — nix flakes only see staged files

2. **Launch** (must run as josh for DISPLAY access):
   ```
   sudo -u josh bash -c 'DISPLAY=:0 NIX_DISK_IMAGE=/agents/ada/projects/loom/loom.qcow2 /agents/ada/projects/loom/result/bin/run-loom-vm'
   ```
   - Do NOT set `QEMU_NET_OPTS` — port forwarding (SSH:2222, HTTP:9090) is already in the flake config; duplicates cause QEMU to fail
   - `/agents/ada` and `/agents/ada/projects` need `o+x` for josh to traverse; `/agents/ada/projects/loom` needs `o+rwx` for disk image creation

3. **SSH in**: `ssh -p 2222 ada@localhost`

4. **HTTP auth server** (port 9090): QEMU SLIRP doesn't relay HTTP data reliably; use SSH tunnel:
   ```
   ssh -L 9091:127.0.0.1:9090 -p 2222 ada@localhost -N
   ```
   Then access at `http://localhost:9091/`

5. **Reset**: `sudo kill <pid> && sudo rm -f /agents/ada/projects/loom/loom.qcow2`
   - Must delete disk to clear persisted credentials from `.claude` directory

## Auth Flow

The kiosk boots into: cage → foot → sudo -u ada → tmux (as ada) → loom-ada-claude wrapper.

The wrapper checks for credentials in order:
1. `.claude/.credentials.json` — full OAuth credentials JSON
2. `.claude/.api-key` — Anthropic API key (`sk-ant-api*`)
3. `.claude/.oauth-token` — setup token from `claude setup-token` (`sk-ant-oat*`)

If none exist, it runs the HTTP auth server on port 9090 (QR code + web form).
After credentials are submitted, wrapper exports the appropriate env var and launches claude.

Token detection:
- `sk-ant-api*` → API key → `.api-key` → `ANTHROPIC_API_KEY`
- `sk-ant-oat*` (or any other `sk-ant-*`) → OAuth token → `.oauth-token` → `CLAUDE_CODE_OAUTH_TOKEN`
- `{*` → credentials JSON → `.credentials.json`
- anything else → treated as OAuth token → `.oauth-token` → `CLAUDE_CODE_OAUTH_TOKEN`

## Key Architecture Decisions

- **tmux runs as ada** — not as the kiosk user. This keeps TMUX socket, BROWSER env, and loom-open all within ada's session boundary.
- **loom-open** splits tmux to show QR codes — claude-code calls $BROWSER or xdg-open, both routed to loom-open.
- **xdg-open shim** is only installed when `!setupComplete` to avoid conflicting with real xdg-open after desktop setup.
