# Authentik SSO Implementation Plan

## Overview
Phased rollout of Authentik as the centralized SSO provider for homelab services, with comprehensive Datadog monitoring and forward authentication via nginx-ingress.

## rollout plan
We must must pause and test in between each task to ensure things are working.  We should keep track of where we are in the next section

## Completed tasks and phases
✅ **Phase 1 - Task 1.1: PostgreSQL Deployment**
- Deployed PostgreSQL 16 with hostPath storage on omen-worker1
- Fixed permission issues (SMB doesn't support chmod/chown)
- Configured readiness/liveness probes
- Database is running and healthy

✅ **Phase 1 - Task 1.1.5: Redis Deployment**
- Deployed Redis 7-alpine as cache for Authentik
- No persistence (ephemeral cache only)
- Resource limits: 256Mi memory, 250m CPU
- Configured with maxmemory and LRU eviction policy
- Running and healthy on omen-worker1

✅ **Phase 1 - Task 1.2: Authentik Deployment (Configuration Files)**
- Created Helm chart with Authentik 2025.10.3
- Configured for external PostgreSQL and Redis
- Added Datadog annotations and monitoring
- Created external secret for Authentik credentials
- Created ingress for auth.tkuipers.ca with TLS
- Configured bootstrap settings
- **Note:** Deployment pending secrets setup (1.5) and ArgoCD Application (1.6)

✅ **Phase 1 - Task 1.5: Setup Script**
- Created setup-authentik-credentials.sh script
- Generates secure secret key, bootstrap password, and token
- Stores credentials in 1Password
- Ready to run: ./tooling/scripts/setup-credentials/setup-authentik-credentials.sh

## Architecture Decisions

### Database
- **PostgreSQL** (dedicated container) - NOT embedded SQLite
- **Redis** for session caching and performance
- Persistent volume backed by SMB storage class (omen-worker1)
- Regular backups via CronJob (daily at 4am Edmonton time)

### Deployment Strategy
- Helm chart deployment (official Authentik chart)
- Infrastructure layer (`clusters/homelab/infrastructure/authentik/`)
- Managed via ArgoCD GitOps
- Secrets via External Secrets Operator (1Password)

### Monitoring Strategy
- Datadog APM integration
- Custom Datadog dashboard for authentication metrics
- Monitors for:
  - Failed login attempts
  - PostgreSQL health
  - Redis health
  - Authentik pod health
  - Forward auth latency
  - Authentication success/failure rates
- Note: Slack notifications disabled initially (to be configured later)

---

## Phase 1: Base Infrastructure Setup

### Objectives
- Deploy Authentik with PostgreSQL backend
- Establish Datadog monitoring
- Create admin access
- Validate basic functionality

### Tasks

#### 1.1 PostgreSQL Deployment
**Files to create:**
- `clusters/homelab/infrastructure/authentik/postgresql-deployment.yaml`
- `clusters/homelab/infrastructure/authentik/postgresql-service.yaml`
- `clusters/homelab/infrastructure/authentik/postgresql-pvc.yaml`
- `clusters/homelab/infrastructure/authentik/postgresql-credentials-external-secret.yaml`

**Specs:**
- Image: `postgres:16-alpine`
- Storage: 10Gi PVC on SMB storage class (smb-omen-worker1)
- Datadog labels for APM tracking
- Resource limits: 512Mi memory, 500m CPU

**1Password Secrets Required:**
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `POSTGRES_DB=authentik`

**Datadog Integration:**
```yaml
annotations:
  ad.datadoghq.com/postgres.check_names: '["postgres"]'
  ad.datadoghq.com/postgres.init_configs: '[{}]'
  ad.datadoghq.com/postgres.logs: '[{"source":"postgresql","service":"authentik-postgres"}]'
labels:
  tags.datadoghq.com/env: homelab
  tags.datadoghq.com/service: authentik-postgres
```

#### 1.1.5 Redis Deployment
**Files to create:**
- `clusters/homelab/infrastructure/authentik/redis-deployment.yaml`
- `clusters/homelab/infrastructure/authentik/redis-service.yaml`

**Specs:**
- Image: `redis:7-alpine`
- No persistence needed (cache only)
- Resource limits: 256Mi memory, 250m CPU

#### 1.2 Authentik Deployment
**Files to create:**
- `clusters/homelab/infrastructure/authentik/namespace.yaml`
- `clusters/homelab/infrastructure/authentik/helm-chart-authentik/Chart.yaml`
- `clusters/homelab/infrastructure/authentik/helm-chart-authentik/values.yaml`
- `clusters/homelab/infrastructure/authentik/authentik-credentials-external-secret.yaml`
- `clusters/homelab/infrastructure/authentik/ingress.yaml`
- `clusters/homelab/infrastructure/authentik/kustomization.yaml`

**Helm Chart:**
```yaml
# Chart.yaml
apiVersion: v2
name: authentik
version: 1.0.0
dependencies:
  - name: authentik
    version: 2024.10.x  # Use latest stable
    repository: https://charts.goauthentik.io
```

**Key values.yaml configurations:**
- External PostgreSQL connection
- External Redis connection
- Datadog APM instrumentation
- Custom domain: `auth.tkuipers.ca`
- Resource requests/limits
- Log shipping to Datadog
- Bootstrap email: `tkuipers123@gmail.com`
- Security hardened for public internet exposure

**1Password Secrets Required:**
- `AUTHENTIK_SECRET_KEY` (generate: `openssl rand -base64 32`)
- `AUTHENTIK_BOOTSTRAP_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_TOKEN`
- `AUTHENTIK_BOOTSTRAP_EMAIL=tkuipers123@gmail.com`
- PostgreSQL connection details

**Ingress:**
- Host: `auth.tkuipers.ca`
- TLS with Let's Encrypt
- External-DNS annotation

#### 1.3 Datadog Authentication Dashboard
**File to create:**
- `clusters/homelab/infrastructure/datadog/authentik-dashboard.yaml`

**Dashboard Widgets:**
1. **Authentication Overview**
   - Total logins (24h)
   - Failed login attempts
   - Active sessions
   - Unique users

2. **Performance Metrics**
   - Forward auth response time (p50, p95, p99)
   - Authentik pod CPU/Memory
   - PostgreSQL connections
   - Database query performance

3. **Security Metrics**
   - Failed login rate
   - Brute force detection alerts
   - Unusual login locations (if configured)
   - Session lifetime distribution

4. **Service Health**
   - Authentik pod status
   - PostgreSQL availability
   - Ingress health checks
   - Certificate expiry warnings

#### 1.4 Datadog Monitors
**Add to:** `clusters/homelab/infrastructure/datadog/datadog-monitors.yaml`

**Monitors to create:**
1. **High Failed Login Rate**
   - Alert: >10 failed logins in 5 minutes from single IP
   - Severity: Warning

2. **Authentik Service Down**
   - Alert: Authentik pods not ready
   - Severity: Critical

3. **PostgreSQL Connection Issues**
   - Alert: Connection pool exhaustion
   - Severity: Critical

3.5. **Redis Unavailability**
   - Alert: Redis pod not ready
   - Severity: Warning

4. **Certificate Expiry**
   - Alert: auth.tkuipers.ca cert expires <14 days
   - Severity: Warning

5. **Forward Auth Latency**
   - Alert: p95 latency >500ms
   - Severity: Warning

#### 1.5 Setup Script
**File to create:**
- `tooling/scripts/setup-credentials/setup-authentik-credentials.sh`

**Script should:**
- Generate secure random keys
- Store secrets in 1Password
- Provide setup instructions
- Validate prerequisites

#### 1.6 ArgoCD Application
**File to create:**
- `clusters/homelab/base/root/applications/argocd-application-authentik.yaml`

**Add to:** `clusters/homelab/base/root/applications/kustomization.yaml`

### Validation Criteria
- [ ] Authentik UI accessible at `https://auth.tkuipers.ca`
- [ ] Admin login successful
- [ ] PostgreSQL connection healthy
- [ ] Datadog dashboard showing metrics
- [ ] All monitors operational
- [ ] External Secrets syncing correctly

---

## Phase 2: Forward Auth Test (Proof of Concept)

### Objectives
- Deploy Authentik forward auth outpost
- Create test application
- Validate authentication flow
- Monitor performance

### Tasks

#### 2.1 Authentik Configuration (UI-based)
1. Create Application in Authentik UI:
   - Name: "Test Forward Auth"
   - Slug: `test-forward-auth`
   - Provider: Forward auth (single application)

2. Create Provider:
   - Type: Proxy Provider
   - Authorization flow: default-provider-authorization-implicit-consent
   - External host: `https://test-auth.tkuipers.ca`

3. Create Outpost:
   - Type: Proxy
   - Integration: Kubernetes (via service account)

#### 2.2 Test Application Deployment
**Files to create:**
- `clusters/homelab/apps/auth-test/namespace.yaml`
- `clusters/homelab/apps/auth-test/deployment.yaml`
- `clusters/homelab/apps/auth-test/service.yaml`
- `clusters/homelab/apps/auth-test/ingress.yaml`
- `clusters/homelab/apps/auth-test/kustomization.yaml`

**Test App:**
- Simple nginx with whoami headers
- Image: `containous/whoami`

**Ingress with Forward Auth:**
```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
  nginx.ingress.kubernetes.io/auth-url: http://authentik-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx
  nginx.ingress.kubernetes.io/auth-signin: https://auth.tkuipers.ca/outpost.goauthentik.io/start?rd=$escaped_request_uri
  nginx.ingress.kubernetes.io/auth-response-headers: Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid
  nginx.ingress.kubernetes.io/auth-snippet: |
    proxy_set_header X-Forwarded-Host $http_host;
```

#### 2.3 Datadog Trace Validation
**Actions:**
1. Add custom traces for auth flow
2. Verify APM showing full request chain
3. Monitor forward auth latency
4. Check for errors in logs

### Validation Criteria
- [ ] Unauthenticated requests redirect to Authentik
- [ ] Successful login redirects back to test app
- [ ] Test app receives authenticated user headers
- [ ] Forward auth latency <200ms (p95)
- [ ] Datadog traces show complete flow
- [ ] No errors in Authentik/nginx logs

---

## Phase 3: Transmission Integration

### Objectives
- Apply forward auth to production service
- Disable Transmission built-in auth
- Validate media download functionality
- Monitor for issues

### Tasks

#### 3.1 Authentik Application Setup
1. Create Application: "Transmission"
2. Create Provider: Forward auth for `transmission.tkuipers.ca`
3. Add to existing outpost

#### 3.2 Transmission Configuration
**File to modify:**
- `clusters/homelab/apps/mediacenter/transmission-deployment.yaml`

**Changes:**
- Add environment variable to disable Transmission auth:
  ```yaml
  - name: TRANSMISSION_RPC_AUTHENTICATION_REQUIRED
    value: "false"
  ```

**File to modify:**
- `clusters/homelab/apps/mediacenter/transmission-ingress.yaml`

**Add annotations:**
```yaml
nginx.ingress.kubernetes.io/auth-url: http://authentik-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx
nginx.ingress.kubernetes.io/auth-signin: https://auth.tkuipers.ca/outpost.goauthentik.io/start?rd=$escaped_request_uri
nginx.ingress.kubernetes.io/auth-response-headers: Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid
nginx.ingress.kubernetes.io/auth-snippet: |
  proxy_set_header X-Forwarded-Host $http_host;
```

#### 3.3 Testing Plan
1. Verify unauthenticated access blocked
2. Test authenticated web UI access
3. Validate downloads still work
4. Check VPN integration still functional
5. Monitor cleanup CronJob still works

#### 3.4 Rollback Plan
**If issues occur:**
1. Remove forward auth annotations from ingress
2. Re-enable Transmission authentication
3. Investigate issues in Datadog/logs
4. Fix and retry

### Validation Criteria
- [ ] Transmission UI requires Authentik login
- [ ] Downloads function normally
- [ ] VPN connection stable
- [ ] Cleanup job executes successfully
- [ ] No increase in error rates
- [ ] Datadog shows healthy metrics

---

## Phase 4: *Arr Stack Integration

### Objectives
- Roll out forward auth to all *arr services
- Maintain API key authentication
- Preserve inter-service communication
- Validate arr-integration-job

### Tasks

#### 4.1 Authentik Applications
Create applications for:
- Sonarr (`sonarr.tkuipers.ca`)
- Radarr (`radarr.tkuipers.ca`)
- Prowlarr (`prowlarr.tkuipers.ca`)
- Bazarr (`bazarr.tkuipers.ca`)
- SABnzbd (`sabnzbd.tkuipers.ca`)

#### 4.2 Service Configuration Updates

**For each *arr service:**

1. **Update ingress files** (add forward auth annotations)
2. **Update deployment** (disable web auth, keep API keys)
3. **Test individually** before moving to next

**Files to modify:**
- `sonarr-ingress.yaml` + `sonarr-deployment.yaml`
- `radarr-ingress.yaml` + `radarr-deployment.yaml`
- `prowlarr-ingress.yaml` + `prowlarr-deployment.yaml`
- `bazarr-ingress.yaml` + `bazarr-deployment.yaml`
- `sabnzbd-ingress.yaml` + `sabnzbd-deployment.yaml`

**Important: API Authentication**
- API keys remain enabled for:
  - Cross-service communication (Sonarr ↔ Prowlarr)
  - External integrations
  - arr-integration-job

**Configuration per service:**

**Sonarr/Radarr:**
```yaml
env:
  - name: SONARR__AUTH__METHOD
    value: "None"  # Disable web auth, API keys still active
```

**Prowlarr:**
```yaml
env:
  - name: PROWLARR__AUTH__METHOD
    value: "None"
```

**Bazarr:**
- Edit via UI after deployment (Settings → General → Authentication: None)

**SABnzbd:**
- Edit via UI or config file

#### 4.3 Integration Testing
**Validate:**
1. Each service accessible only after auth
2. arr-integration-job completes successfully
3. Prowlarr syncing works
4. Sonarr/Radarr can search via Prowlarr
5. Download automation flows work end-to-end

#### 4.4 Monitoring Updates
**Add to Datadog dashboard:**
- *Arr service authentication metrics
- API call success rates
- Integration job execution status

### Validation Criteria
- [ ] All *arr services require SSO login
- [ ] Inter-service API calls work
- [ ] arr-integration-job succeeds
- [ ] Search/download automation functional
- [ ] No increase in error rates
- [ ] Datadog metrics healthy

---

## Phase 5: Native OIDC Integrations

### Objectives
- Configure native OIDC for services that support it
- Better integration than forward auth
- Cleaner user experience

### Tasks

#### 5.1 ArgoCD OIDC Integration

**File to modify:**
- `clusters/homelab/base/argocd/argocd-configmap-argocd-cm.yaml`

**Authentik Configuration:**
1. Create OAuth2/OpenID Provider in Authentik
   - Client ID: `argocd`
   - Client Secret: (store in 1Password)
   - Redirect URI: `https://argo.tkuipers.ca/auth/callback`
   - Scopes: openid, profile, email, groups

2. Add ArgoCD application to Authentik

**ArgoCD Configuration:**
```yaml
data:
  oidc.config: |
    name: Authentik
    issuer: https://auth.tkuipers.ca/application/o/argocd/
    clientID: argocd
    clientSecret: $oidc.authentik.clientSecret
    requestedScopes: ["openid", "profile", "email", "groups"]
    requestedIDTokenClaims:
      groups:
        essential: true
  
  # Map Authentik groups to ArgoCD roles
  policy.csv: |
    g, authentik Admins, role:admin
    g, authentik DevOps, role:admin
```

**ExternalSecret for client secret:**
- `clusters/homelab/base/argocd/argocd-oidc-secret-external-secret.yaml`

**Testing:**
1. Logout of ArgoCD
2. Click "Login with Authentik"
3. Verify SSO login works
4. Check group/role mapping

#### 5.2 Jellyfin OIDC Plugin

**Authentik Configuration:**
1. Create OAuth2/OpenID Provider
   - Client ID: `jellyfin`
   - Redirect URI: `https://jellyfin.tkuipers.ca/sso/OID/redirect/authentik`

**Jellyfin Configuration:**
1. Install SSO plugin (requires Jellyfin admin UI)
2. Configure plugin with:
   - Provider: Custom
   - Client ID/Secret from Authentik
   - Discovery URL: `https://auth.tkuipers.ca/application/o/jellyfin/.well-known/openid-configuration`

**Testing:**
1. Access Jellyfin
2. SSO login option appears
3. Verify user creation on first login
4. Validate media playback still works

#### 5.3 Homepage Dashboard Integration

**If upgrading to Homarr/Heimdall:**
- Configure OIDC integration
- Otherwise: Keep forward auth or no auth (internal dashboard)

### Validation Criteria
- [ ] ArgoCD OIDC login works
- [ ] Group/role mapping correct
- [ ] Jellyfin SSO functional
- [ ] User provisioning works
- [ ] No loss of existing functionality

---

## Phase 6: Production Hardening

### Objectives
- Implement advanced security features
- Optimize performance
- Establish backup/recovery procedures

### Tasks

#### 6.1 Security Hardening

**Authentik Configuration:**
1. **Multi-factor Authentication**
   - Enable TOTP/WebAuthn
   - Enforce MFA for admin users
   - Optional MFA for regular users

2. **Brute Force Protection**
   - Rate limiting policies
   - IP reputation integration
   - Account lockout after N failed attempts

3. **Session Management**
   - Session timeout: 24 hours
   - Concurrent session limits
   - Secure cookie settings

4. **Network Policies**
   - Create Kubernetes NetworkPolicy
   - Only allow ingress-nginx → authentik
   - PostgreSQL only accessible from Authentik

**Files to create:**
- `clusters/homelab/infrastructure/authentik/networkpolicy.yaml`

#### 6.2 Backup Strategy

**PostgreSQL Backups:**
**File to create:**
- `clusters/homelab/infrastructure/authentik/backup-cronjob.yaml`

**Backup plan:**
- Daily pg_dump to SMB storage at 4am Edmonton time (10am/11am UTC depending on DST)
- 7-day retention
- Test restore procedure monthly

**Authentik Configuration Backup:**
- Export flows/policies via Authentik UI
- Store in Git (without secrets)
- Automated export job (optional)

#### 6.3 Performance Optimization

**Monitoring targets:**
- Forward auth latency: <100ms (p95)
- PostgreSQL query time: <50ms (p95)
- Redis response time: <10ms (p95)
- Authentik response time: <200ms (p95)

**Optimizations if needed:**
- Increase outpost replicas
- Database connection pooling tuning
- Redis persistence tuning (currently cache-only)
- CDN for static assets (optional)

#### 6.4 Documentation

**Create operational runbook:**
- User management procedures
- Adding new applications
- Troubleshooting guide
- Backup/restore procedures
- Rollback procedures

### Validation Criteria
- [ ] MFA enforced for admins
- [ ] Network policies active
- [ ] Backups running successfully
- [ ] Performance within targets
- [ ] Runbook complete

---

## Phase 7: Advanced Features (Future)

### Optional Enhancements

#### 7.1 User Self-Service
- Password reset flow
- Profile management
- MFA enrollment

#### 7.2 External Identity Providers
- Google OAuth
- GitHub OAuth
- Corporate LDAP/AD (if needed)

#### 7.3 Advanced Authorization
- Attribute-based access control (ABAC)
- Time-based access restrictions
- IP-based policies

#### 7.4 Audit Logging
- Enhanced audit trails
- SIEM integration
- Compliance reporting

---

## Rollback Procedures

### Emergency Rollback

**If critical issues occur:**

1. **Remove ArgoCD Application**
   ```bash
   kubectl delete application authentik -n argocd
   ```

2. **Remove forward auth annotations**
   - Commit removal of auth annotations
   - Push to Git
   - ArgoCD will sync automatically

3. **Re-enable service authentication**
   - Revert deployment changes
   - Re-enable built-in auth on services

### Partial Rollback

**If specific service has issues:**
1. Remove forward auth from that service's ingress
2. Re-enable built-in auth for that service only
3. Keep other services on SSO

---

## Success Metrics

### Technical Metrics
- Forward auth latency: <100ms (p95)
- Authentication success rate: >99.5%
- System uptime: >99.9%
- Zero security incidents

### Operational Metrics
- Time to add new service: <10 minutes
- User onboarding time: <5 minutes
- MFA enrollment rate: 100% (admins)

### User Experience
- Single login for all services
- Session persistence across services
- No duplicate login prompts

---

## Configuration Summary

**Confirmed Settings:**
- Domain: `auth.tkuipers.ca`
- Storage: SMB on omen-worker1
- Database: PostgreSQL + Redis (both deployed)
- Admin: tkuipers123@gmail.com
- Backup time: 4am Edmonton time (MST/MDT)
- Security posture: Hardened for public internet
- Initial users: Single admin account (additional via web UI)
- Notifications: TBD (no Slack initially)

## Prerequisites Checklist

Before starting:
- [ ] PostgreSQL storage requirements: 10Gi on smb-omen-worker1 ✓
- [ ] Redis deployment included ✓
- [ ] Domain DNS configured (auth.tkuipers.ca)
- [ ] 1Password vault access
- [ ] Datadog API access
- [ ] ArgoCD access
- [ ] Understanding of forward auth concepts

---

## Timeline Estimate

- **Phase 1** (Base Setup): 4-6 hours
- **Phase 2** (PoC): 2-3 hours
- **Phase 3** (Transmission): 1-2 hours
- **Phase 4** (*Arr Stack): 3-4 hours
- **Phase 5** (Native OIDC): 2-3 hours
- **Phase 6** (Hardening): 3-4 hours

**Total: ~15-22 hours** (spread over multiple sessions)

---

## Notes

- Each phase should be completed and validated before moving to next
- Keep Git commits granular (one service at a time)
- Monitor Datadog dashboard after each change
- Test authentication AND functionality after each change
- Document any deviations from this plan

---

## Next Steps

1. Review this plan
2. Create setup script for Authentik credentials
3. Begin Phase 1: Base Infrastructure Setup

