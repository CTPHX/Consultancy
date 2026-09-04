# AVD Manager — Production Hardening Checklist

This is a living checklist of development-only choices, temporary shortcuts, and production changes to address before release.

## Identity and authentication

- [ ] Replace development client secret with a production-grade credential approach (prefer certificate or managed identity where applicable).
- [ ] Remove any development-only redirect URIs such as localhost and Codespaces `app.github.dev` callbacks.
- [ ] Configure final production App Service redirect URI(s).
- [ ] Confirm supported account type for commercial model (single-tenant vs multi-tenant SaaS).
- [ ] Review whether Azure Service Management delegated `user_impersonation` is still required. Remove if app-only discovery is adopted.
- [ ] Move sign-in explicitly to the modern OpenID Connect authorization-code flow for production and remove the development dependency on Entra implicit/hybrid `id_token` issuance.
- [ ] Disable the App Registration's **Implicit grant and hybrid flows → ID tokens** setting once the production authorization-code flow is verified.
- [ ] Add explicit sign-out flow and production front-channel logout URI.
- [ ] Add application authorization / AVD Manager roles so successful Entra sign-in alone does not grant admin access.
- [ ] Review Conditional Access compatibility and MFA expectations.
- [ ] Persist data-protection keys outside ephemeral container storage.

## Azure discovery identity

- [ ] Use an application/service identity for Azure discovery rather than relying on the signed-in user's Azure RBAC.
- [ ] Prefer App Service managed identity for production ARM access where practical.
- [ ] Scope Reader permissions only to configured customer subscriptions/resource groups rather than broad tenant access.
- [ ] Keep discovery read-only.
- [ ] Separate discovery permissions from Automation job execution permissions.
- [ ] Document the minimum RBAC roles required for customer onboarding.

## Azure Automation integration

- [ ] Keep the existing Automation Account managed identity as the privileged execution identity.
- [ ] Give the web application only the minimum rights required to start/read approved runbooks and jobs.
- [ ] Do not grant the web application broad Contributor permissions over customer subscriptions.
- [ ] Restrict which runbooks AVD Manager is permitted to invoke.
- [ ] Validate and whitelist runbook parameters server-side.
- [ ] Add destructive-operation confirmation and audit records before job submission.

## Secrets and configuration

- [ ] No client secrets, storage keys, domain credentials, registration tokens, or Key Vault secrets in source control.
- [ ] Move production configuration to App Service settings / Key Vault references as appropriate.
- [ ] Add separate Development, Test and Production configuration.
- [ ] Ensure secrets are never rendered in logs, error pages or audit records.
- [ ] Add secret/certificate rotation procedure.

## Hosting and networking

- [ ] Deploy to Azure App Service rather than Codespaces.
- [ ] Remove Codespaces-specific forwarded-host assumptions if no longer required; retain correct reverse-proxy handling for App Service.
- [ ] Enforce HTTPS only.
- [ ] Configure custom domain and managed certificate if required.
- [ ] Consider Private Endpoints/VNet integration where customer architecture requires them.
- [ ] Configure appropriate App Service access restrictions/WAF strategy.
- [ ] Verify outbound connectivity to Entra, Azure Resource Manager and required Azure endpoints.

## Data and persistence

- [ ] Move environment/customer configuration from browser/local placeholders to persistent storage (planned Azure SQL).
- [ ] Persist the selected subscription/environment so Settings can re-scan the configured Azure subscription without asking the user to select it again.
- [ ] Persist discovery/mapping snapshots and record the last successful scan timestamp so re-scans can safely refresh changed Azure resources.
- [ ] Define how re-scan handles resources that were added, removed, renamed or moved while preserving explicit administrator mapping overrides.
- [ ] Encrypt sensitive configuration at rest.
- [ ] Add customer/tenant/environment isolation to every persisted entity.
- [ ] Add database migrations, backup, restore and retention strategy.
- [ ] Define data retention for job output and audit logs.

## Audit and security controls

- [ ] Record user, tenant, environment, operation, parameters, runbook, Automation job ID, result and timestamp.
- [ ] Record destructive actions separately and retain them for the agreed audit period.
- [ ] Add server-side authorization checks on every operation, not just UI hiding.
- [ ] Add CSRF protection and review cookie security settings.
- [ ] Add rate limiting / abuse protection where appropriate.
- [ ] Add security headers and review CSP.
- [ ] Perform least-privilege review of every Azure role before release.

## Reliability and operations

- [ ] Add Application Insights and structured logging.
- [ ] Add health checks for Azure SQL, ARM connectivity and Automation connectivity.
- [ ] Add friendly production error pages; do not expose stack traces.
- [ ] Add retry/backoff for Azure API throttling and transient failures.
- [ ] Add timeouts and cancellation for long-running discovery operations.
- [ ] Add monitoring/alerts for authentication failures, job failures and application errors.
- [ ] Validate scale-out behavior and distributed token/session handling.

## Commercial / multi-customer readiness

- [ ] Implement customer / Entra tenant / environment model.
- [ ] Implement license status, plan, expiry and feature entitlements.
- [ ] Decide final tenant onboarding model and consent process.
- [ ] Provide a repeatable customer RBAC onboarding script/template.
- [ ] Separate MSP access from customer-local administrator access.
- [ ] Add terms/privacy/support links before public release.

## Current development-specific items already identified

- [ ] Codespaces port 5000 is temporarily public for Entra callback testing; do not treat this as a production hosting pattern.
- [ ] Codespaces uses a temporary client secret via .NET user-secrets.
- [ ] Localhost and Codespaces redirect URIs are development-only.
- [ ] Entra **Implicit grant and hybrid flows → ID tokens** is temporarily enabled for Codespaces/development sign-in and must be removed after production authorization-code flow is verified.
- [ ] ASP.NET currently uses in-memory token caches; production scale-out requires a shared/distributed token cache strategy if delegated tokens remain in use.
- [ ] Data-protection keys are currently stored in the Codespaces container filesystem and are not durable.
- [ ] No production `/Error` page has yet been implemented.
- [ ] Azure discovery implementation is not yet complete.
- [ ] Settings re-scan currently falls back to subscription selection until environment persistence is implemented; production should re-scan the persisted configured environment directly.
