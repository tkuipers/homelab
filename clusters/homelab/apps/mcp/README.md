# mcp

MCP servers the homelab agent (`apps/homelab-agent`) uses over HTTP. Each one is registered
in the agent (Settings > MCP servers), where Tyler chooses per persona whether it's Off, Ask
(every call waits for his approval) or Auto, with per-tool overrides.

## google-workspace-mcp (Gmail)

- [taylorwilsdon/google_workspace_mcp](https://github.com/taylorwilsdon/google_workspace_mcp)
  1.29.0, Gmail tools only (`--permissions gmail:send`), single user `tkuipers123@gmail.com`.
  Image: `ghcr.io/tkuipers/workspace-mcp`, built from `homelab-agent/images/workspace-mcp`
  (dependencies hash-locked); CI pins both images in `kustomization.yaml`.
- No auth of its own, so it listens on 127.0.0.1 and the `gate` sidecar requires the shared
  `Authorization` header (secret `google-mcp-gate`, generated here, pushed to 1Password
  "Google MCP Gate", read by the agent). Only `/oauth2callback` is exposed, behind Authelia.
- Google OAuth client: 1Password "Google Workspace MCP" (`client-id`, `client-secret`), a
  Web client with redirect URI `https://google-mcp.tkuipers.ca/oauth2callback`, app published
  "In production" (Testing apps' refresh tokens expire after 7 days).
- First sign-in: ask the agent to use Gmail; it calls `start_google_auth` and sends the link.
  The refresh token is stored on the PVC (local-path: the pod stays on its first node).

## browser-mcp (web browser)

- [microsoft/playwright-mcp](https://github.com/microsoft/playwright-mcp) 0.0.83, the upstream
  image pinned by digest in `browser.yaml`: headless Chromium, `--isolated` (every session starts
  fresh and logged out; nothing is kept).
- Its own namespace `mcp-browser` (privileged): a firewall init container lets it reach the
  internet but nothing private (cluster, LAN) except the cluster DNS. The running containers drop
  all capabilities and run as non-root.
- Same gate as Gmail: listens on 127.0.0.1, the `gate` sidecar requires the token (secret
  `browser-mcp-gate`, generated here, pushed to 1Password "Browser MCP Gate", read by the agent).
  Nothing is exposed through an ingress.
- The agent attaches it to the Assistant as the system server `browser` (`BROWSER_MCP_URL`); clicks
  that book, pay, confirm or submit wait for Tyler's approval (policy rule `browser-commit`).
