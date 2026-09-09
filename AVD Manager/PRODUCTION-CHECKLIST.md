# AVD Manager — Production Hardening Checklist

This is a living checklist of development-only choices, temporary shortcuts, and production changes to address before release.

## Identity and authentication
- [ ] Replace development client secret with a production-grade credential approach (prefer certificate or managed identity where applicable).
- [ ] Remove development-only localhost/Codespaces redirect URIs and configure final App Service redirect URI(s).
- [ ] Confirm single-tenant vs multi-tenant commercial model.
- [ ] Remove delegated Azure Service Management `user_impersonation` if unused.
- [ ] Move sign-in explicitly to authorization-code flow and disable development-only implicit/hybrid ID tokens.
- [ ] Add explicit sign-out/front-channel logout, AVD Manager app roles, Conditional Access/MFA review and durable Data Protection keys.

## Azure discovery and operational identity
- [ ] Use production App Service managed identity/service identity for ARM access.
- [ ] Keep discovery at least-privilege Reader scope and separately document minimum operational permissions.
- [ ] Remove temporary development Contributor assignment before production.
- [ ] Maintain `ACCESS-REQUIREMENTS.md` and build/test least-privilege custom roles from it.
- [ ] Review separate discovery/read and operational/write production roles.
- [ ] Document customer onboarding RBAC and AVD Manager app roles.

## Azure Automation integration
- [ ] Keep the existing Automation Account managed identity as the privileged execution identity for complex runbooks.
- [ ] Give the web application only minimum start/read rights for approved runbooks; do not grant broad Contributor.
- [ ] Restrict runbooks, validate/whitelist parameters server-side, and audit destructive operations.
- [ ] Validate the selected Automation Account and published `DeployAVDHosts` runbook before enabling deployment.
- [ ] Persist Automation Job ID, status, streams/output and final result so deployment history survives browser disconnects and app restarts.
- [ ] Keep simple AVD/Compute state operations on the direct ARM API path.

## Durable replacement / grace-period workflow
- [ ] V1: persist replacement operation state outside the browser; browser closure must not stop the drain/grace workflow.
- [ ] V1: drain existing hosts, record grace-period deadline and force-logoff policy, re-check live sessions before every destructive transition, and require zero sessions before starting the replacement runbook.
- [ ] V1: on application restart, recover outstanding operations from durable storage and reconcile current Azure state before continuing. Never infer that a previously observed zero-session state is still valid.
- [ ] V1 safety: if AVD Manager is offline when a grace deadline expires, do nothing destructive while offline; resume only after the app returns and current state is revalidated.
- [ ] Production hardening: move deadline/session monitoring to an Azure-side durable scheduler/worker (for example Durable Functions or equivalent) so grace-period deadlines can fire even while the web application is completely unavailable.
- [ ] Production hardening: make deadline processing idempotent, use leases/locking for scale-out, record transition/audit history, and prevent duplicate Automation job submission.

## Direct AVD / Compute operational API
- [ ] Add authorization/app-role checks and durable audit records around drain mode, user logoff and VM power operations.
- [ ] Replace raw Azure API messages shown to users with friendly errors while retaining protected diagnostics.
- [ ] Add retry/backoff and partial-failure handling for bulk operations.
- [ ] Reconcile UI state from Azure after direct operations.
- [ ] Confirm production custom role includes only required AVD/Compute actions from the access ledger.
- [ ] Keep stop/deallocate safety rule enforced server-side: selected hosts must be in drain mode.
- [ ] Review restart policy before production.
- [ ] Add explicit VM power-state display/reconciliation.
- [ ] Replace remaining request-bound progress with durable operation/job tracking.

## Secrets and configuration
- [ ] Keep all secrets out of source; use App Service settings/Key Vault references and separate environments.
- [ ] Prevent secrets appearing in logs/errors/audit records and define rotation procedures.

## Hosting and networking
- [ ] Deploy to Azure App Service, remove Codespaces-specific assumptions, enforce HTTPS and review VNet/private endpoint/access restrictions.

## Data and persistence
- [ ] Replace development `App_Data/environment.json` with Azure SQL before production.
- [ ] Store durable deployment/replacement operations in Azure SQL for production; do not rely on process memory or browser state.
- [ ] Persist customer/tenant/environment/subscription, selected mappings, Automation configuration, discovery snapshots and scan timestamps.
- [ ] Re-scan persisted subscription and preserve explicit administrator overrides.
- [ ] Define handling for resources added, removed, renamed or moved.
- [ ] Add tenant isolation, migrations, backup/restore, retention and encryption-at-rest controls.

## Audit and security controls
- [ ] Record user, tenant, environment, operation, parameters, runbook/job ID, result and timestamp.
- [ ] Add server-side authorization, CSRF review, cookie hardening, rate limiting, security headers/CSP and least-privilege review.

## Reliability and operations
- [ ] Add Application Insights/structured logging, health checks, production error pages, retry/backoff, timeouts/cancellation, alerts and scale-out validation.

## Commercial / multi-customer readiness
- [ ] Implement customer/Entra tenant/environment model, licensing/entitlements, onboarding/consent, repeatable RBAC deployment and MSP/customer role separation.
- [ ] Add terms/privacy/support links before public release.

## Current development-specific items already identified
- [ ] Codespaces port 5000 is temporarily public for Entra callback testing.
- [ ] Codespaces uses a temporary client secret via .NET user-secrets.
- [ ] Localhost and Codespaces redirect URIs are development-only.
- [ ] Entra implicit/hybrid ID tokens are temporary and must be removed after production auth-code flow verification.
- [ ] ASP.NET token caches and Data Protection keys are not yet durable/distributed.
- [ ] No production `/Error` page has yet been implemented.
- [ ] Azure discovery will continue to expand as operational screens are built.
- [ ] Environment configuration persists locally to `App_Data/environment.json` for development only; production must use Azure SQL.
