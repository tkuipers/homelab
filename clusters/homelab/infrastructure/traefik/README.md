# Traefik (ingress controller)

Replaces ingress-nginx, which was archived upstream in March 2026 and gets no more
nginx security fixes (e.g. the November 2026 "NGINX2Root" CVEs).

- Traefik's `kubernetesIngressNGINX` provider serves every Ingress of class `nginx`
  and translates the `nginx.ingress.kubernetes.io/*` annotations (auth-url/auth-signin,
  proxy-body-size, timeouts, limit-rpm/limit-connections, rewrite-target, upstream-vhost,
  temporal-redirect...). App manifests don't change; keep writing nginx annotations.
  Supported and unsupported annotations:
  https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/ingress-nginx/
- Authelia: use `auth-url: http://authelia.authelia.svc.cluster.local/api/authz/forward-auth`.
  Not `/api/authz/auth-request`: that endpoint trusts `X-Original-URL`, which Traefik
  passes through from the client, while it always overwrites the `X-Forwarded-*`
  headers that forward-auth reads.
- No proxy sits in front (router port-forward, `externalTrafficPolicy: Local`), so
  client `X-Forwarded-*` headers are never trusted.
- Metrics: `traefik_router_*` with the router label
  `<namespace>-<len>-<ingress>-<len>-rule-<n>-path-<m>[-tls]@kubernetesingressnginx`;
  the ServiceMonitor relabels it to `exported_namespace` / `ingress`.
- Access logs are JSON on stdout (Alloy: `log_format=access_traefik`).
