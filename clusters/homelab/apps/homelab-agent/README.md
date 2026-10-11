# Homelab agent

A Claude Code agent (Claude Agent SDK) that keeps this cluster healthy. Source,
design and configuration: github.com/tkuipers/homelab-agent (private). Image
`ghcr.io/tkuipers/homelab-agent:latest` (`imagePullPolicy: Always`; roll out
with `kubectl -n homelab-agent rollout restart deploy/homelab-agent`).

- **Web UI**: https://agent.tkuipers.ca (Authelia) - every conversation's live
  transcript, chat, "scan now", Claude sign-in (`/#/auth`), the agent's notes.
- **Triggers**: Grafana + Alertmanager webhooks (`/hooks/grafana`,
  `/hooks/alertmanager`, bearer token), a daily scan at 06:00 America/Toronto
  of the last 24h of logs/metrics/events (Grafana MCP, read-only service
  account), and texts from Tyler.
- **SMS** (Twilio, one number): `https://agent.tkuipers.ca/hooks/sms` is public
  (separate Ingress without Authelia) and checked against Twilio's signature;
  only `sms-allowed-numbers` may talk to it. Text `/help` for the commands.
- **Changes** go to `main` through a write deploy key; commits carry an
  `Agent-Run:` trailer. kubectl (ServiceAccount `homelab-agent`, `rbac.yaml`):
  read everything but Secrets, restarts and minor live edits that the agent
  must commit before it finishes.
- **relay**: same image with `MODE=relay`; texts Grafana alerts about the agent
  itself (down, daily scan overdue).
- **Data**: `/data` (local-path PVC on dell-r620): conversations, Claude Code
  sessions, the OAuth token, notes, per-conversation git worktrees.
- **Logs/metrics**: JSON logs in Loki (`{service_name="homelab-agent"}`),
  `homelab_agent_*` metrics, dashboard *Apps / Homelab agent*.

Credentials: `tooling/scripts/setup-credentials/setup-homelab-agent-credentials.sh`
(1Password item "Homelab Agent Credentials").
