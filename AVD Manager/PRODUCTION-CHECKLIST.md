# AVD Manager — Production Hardening Checklist

This is a living checklist of development-only choices, temporary shortcuts, and production changes to address before release.

## Identity and authentication
- [ ] Replace development client secret with a production-grade credential approach (prefer certificate or managed identity where applicable).
- [ ] Remove development-only localhost/Codespaces redirect URIs and configure final App Service redirect URI(s).
- [ ] Confirm single-tenant vs multi-tenant commercial model.
- [ ] Remove delegated Azure Service Management `user_impersonation` if unused.
- [ ] Move sign-in explicitly to authorization-code flow and disable development-only implicit/hybrid ID tokens.
- [ ] Add explicit sign-out/front-channel logout, AVD Manager app roles, Conditional Access/MFA review and durable Data Protection keys.

## Azure discovery identity
- [ ] Use production App Service managed identity/service identity for ARM discovery with least-privilege Reader scope.
- [ ] Keep discovery read-only and separate from Automation execution permissions.
- [ ] Document minimum customer onboarding RBAC.

## Azure Automation integration
- [ ] Keep the existing Automation Account managed identity as the privileged execution identity.
- [ ] Give the web application only minimum start/read rights for approved runbooks; do not grant broad Contributor.
- [ ] Restrict runbooks, validate/whitelist parameters server-side, and audit destructive operations.

## Secrets and configuration
- [ ] Keep all secrets out of source; use App Service settings/Key Vault references and separate Development/Test/Production configuration.
- [ ] Prevent secrets appearing in logs/errors/audit records and define rotation procedures.

## Hosting and networking
- [ ] Deploy to Azure App Service, remove Codespaces-specific assumptions, enforce HTTPS, configure production domain/certificate and review VNet/private endpoint/access restriction requirements.

## Data and persistence
- [ ] **Replace the current development `App_Data/environment.json` configuration store with Azure SQL before production.** The file store is deliberately temporary and is not suitable for App Service scale-out, customer isolation, backup or durable configuration.
- [ ] Persist customer/tenant/environment/subscription, selected deployment mappings, discovery snapshots and last successful scan timestamp in Azure SQL.
- [ ] Re-scan the persisted configured subscription directly and merge newly discovered Azure state while preserving explicit administrator mapping overrides.
- [ ] Define handling for resources added, removed, renamed or moved between scans.
- [ ] Add tenant isolation to every persisted entity, migrations, backup/restore, retention and encryption-at-rest controls.

## Audit and security controls
- [ ] Record user, tenant, environment, operation, parameters, runbook/job ID, result and timestamp; retain destructive actions appropriately.
- [ ] Add server-side authorization, CSRF review, cookie hardening, rate limiting, security headers/CSP and least-privilege review.

## Reliability and operations
- [ ] Add Application Insights/structured logging, health checks, production error pages, retry/backoff, discovery timeouts/cancellation, alerts and scale-out validation.

## Commercial / multi-customer readiness
- [ ] Implement customer/Entra tenant/environment model, licensing/entitlements, onboarding/consent, repeatable RBAC deployment and MSP/customer role separation.
- [ ] Add terms/privacy/support links before public release.

## Current development-specific items already identified
- [ ] Codespaces port 5000 is temporarily public for Entra callback testing.
- [ ] Codespaces uses a temporary client secret via .NET user-secrets; Codespace rebuilds can lose it.
- [ ] Localhost and Codespaces redirect URIs are development-only.
- [ ] Entra **Implicit grant and hybrid flows → ID tokens** is temporarily enabled and must be removed after production authorization-code flow is verified.
- [ ] ASP.NET token caches and Data Protection keys are not yet durable/distributed.
- [ ] No production `/Error` page has yet been implemented.
- [ ] Azure discovery will continue to expand as operational screens are built.
- [ ] Environment configuration now persists locally to `App_Data/environment.json` for development only; production must use Azure SQL.
