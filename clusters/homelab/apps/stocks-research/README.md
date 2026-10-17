# stocks-research

Overnight research on the stocks cross-sectional model (stock-guesser v2,
Feature 20: `docs/features/20-overnight-research/README.md`).

- **What:** the training image running `stock_guesser_training.research.app`
  on port 8090 (`http://research.stocks-research.svc:8090`, in-cluster only).
  It snapshots the price history once a night, evaluates queued experiments
  against the live champion, follows promising ones forward, and decides with
  a fixed gate whether one has earned promotion (`GET /v1/promotion`).
- **Isolation:** no production credentials and no Kubernetes API token. It reads
  production only through `GET /v1/xsec/universe` and `GET /v1/xsec/champion`
  on the training service, and writes only to its own PVC.
- **When:** work happens only inside `RESEARCH_WINDOW_UTC` (07:00–13:00), after
  the nightly bake-off and before the 09:35-ET run. The homelab agent's nightly
  schedule (02:00 America/Edmonton) proposes experiments and applies promotions.
- **Promotion:** the gate-approved values go into
  `apps/stocks/xsec-champion.env` (only inside 07:00–12:00 UTC). Argo CD rolls
  training and decision; training refits with the new config at startup.
  Reverting a promotion is reverting that commit.
- **Data:** PVC `research-data` (local-path, omen-worker1): last 3 snapshots and
  `ledger.sqlite` (every experiment, journal, champion changes). Disposable for
  production; losing it resets the research history and the gate's trial count.
