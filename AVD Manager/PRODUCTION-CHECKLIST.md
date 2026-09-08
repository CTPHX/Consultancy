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
- [ ] Keep discovery at least-privilege Reader scope and separately document the minimum operational permissions needed for direct AVD session-host updates.
- [ ] Define a custom least-privilege role for AVD Manager operational actions rather than granting broad Contributor; scope it to the configured AVD resource group/host pools where practical.
- [ ] Document minimum customer onboarding RBAC and separate read-only users from operators through AVD Manager app roles.

## Azure Automation integration
- [ ] Keep the existing Automation Account managed identity as the privileged execution identity for complex runbook workflows such as deployment, image management and FSLogix operations.
- [ ] Give the web application only minimum start/read rights for approved runbooks when an operation actually requires Automation; do not grant broad Contributor.
- [ ] Restrict runbooks, validate/whitelist parameters server-side, and audit destructive operations.
- [ ] Keep simple AVD resource state operations such as session-host drain mode on the direct ARM API path rather than routing them through Automation.

## Direct AVD operational API
- [ ] Add authorization/app-role checks and durable audit records around single and bulk drain-mode changes.
- [ ] Replace raw Azure authorization/API messages shown to users with friendly errors while retaining structured diagnostic detail in protected logs.
- [ ] Add retry/backoff and partial-failure handling for bulk host operations; never silently report a partially successful bulk action as fully successful.
- [ ] Reconcile UI state from Azure after direct operations and record the requested and resulting `allowNewSession` state.

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
- [ ] Record user, tenant, environment, operation, parameters, runbook/job ID where applicable, result and timestamp; retain destructive actions appropriately.
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
