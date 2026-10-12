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

## google-workspace-mcp-assistant (the assistant's own Gmail)

- A second instance for `tyler.kuipers.ai@gmail.com`, the account the agent uses for "Sign in
  with Google" on booking sites. Same image and OAuth client, its own volume, gate token
  (1Password "Google MCP Gate Assistant") and callback host `google-mcp-assistant.tkuipers.ca`
  (add `https://google-mcp-assistant.tkuipers.ca/oauth2callback` to the OAuth client's redirect URIs).
- Registered in the agent as `gmail_assistant`, separate from `gmail`, so the two accounts get
  their own Off / Ask / Auto settings.

## browser-mcp (web browser)

- [microsoft/playwright-mcp](https://github.com/microsoft/playwright-mcp) 0.0.83, the upstream
  image pinned by digest in `browser.yaml`: headless Chromium, `--isolated` (every session starts
  fresh and logged out; nothing is kept).
- Only allow-listed hosts: Chromium goes through the `egress` proxy sidecar, which uses the agent's
  allow-list and Jev vetting (blocked hosts show up in the agent's UI to allow).
- Its own namespace `mcp-browser` (privileged) for the firewall init container: only the proxy's
  user gets out, never to private ranges (cluster, LAN) or our public IP (`agent.tkuipers.ca` and
  checkip, resolved when the pod starts; restart the pod if the public IP changes). The running
  containers drop all capabilities and run as non-root.
- Same gate as Gmail: listens on 127.0.0.1, the `gate` sidecar requires the token (secret
  `browser-mcp-gate`, generated here, pushed to 1Password "Browser MCP Gate", read by the agent).
  The proxy shows the same token to the agent's `/internal/egress` API. No ingress.
- The agent attaches it to the Assistant as the system server `browser` (`BROWSER_MCP_URL`).
  Clicks, Enter, typing with submit, form fills and uploads that commit something or touch a
  password or card field wait for Tyler's approval, judged from the live page.

## arr-mcp (Sonarr and Radarr)

- [aplaceforallmystuff/mcp-arr](https://github.com/aplaceforallmystuff/mcp-arr) 1.7.3, the
  upstream image pinned by digest in `arr.yaml`, Streamable HTTP. Only Sonarr and Radarr are
  configured (series/movies, search and add, queue, calendar, episodes, config review, TRaSH guides).
- API keys: the ones Prowlarr, Jellyseerr and exportarr already use, read at start from each app's
  `config.xml` (hostPath on dell-r620, only that file, read-only), like the arr-integration-job.
  So it has its own namespace `mcp-arr` (privileged for hostPath; the containers run restricted)
  and is pinned to dell-r620. Restart it if an API key is regenerated. Adding Prowlarr: mount its
  config.xml and set `PROWLARR_URL`/`PROWLARR_API_KEY` the same way.
- Same gate as Gmail: listens on 127.0.0.1, the `gate` sidecar requires the token (secret
  `arr-mcp-gate`, generated here, pushed to 1Password "Arr MCP Gate", read by the agent). No ingress.
- The agent registers it as the system server `arr` (`ARR_MCP_URL`) for Ops and the Assistant.
