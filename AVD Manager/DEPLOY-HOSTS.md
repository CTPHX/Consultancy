# Deploy Hosts – Deployment Options

This guide describes the deployment choices available on the **Deploy Hosts** page in AVD Manager and the expected behaviour of each option.

## Standard deployment

Leave **Replace existing session hosts** unticked.

AVD Manager prepares a request to deploy the requested number of new session hosts to the selected host pool. Existing session hosts are not placed into the replacement drain/grace workflow.

Use this when adding capacity rather than replacing existing hosts.

## Replace existing session hosts

Tick **Replace existing session hosts** when the new hosts are intended to replace the hosts already registered with the selected host pool.

When the workflow starts, AVD Manager immediately prevents new sessions from being placed on the existing hosts by putting them into drain mode. Existing user sessions are then handled according to the selected grace-period and forced-logoff options.

Existing hosts must not be removed while active sessions remain unless the selected forced-logoff policy has first dealt with those sessions.

Each host pool is handled as an independent durable deployment operation.

## Grace period

The grace period controls how long existing users are allowed to remain on the drained session hosts.

### Immediate

There is no waiting period.

What happens next depends on **Force log off remaining users immediately**:

- **Force log off OFF:** existing hosts are drained immediately, but connected users are not forcibly signed out. If sessions remain, the operation must wait for those users to leave normally before replacement can continue.
- **Force log off ON:** when the workflow reaches the logoff stage, remaining sessions are eligible for immediate forced logoff. Replacement can then continue once the sessions have cleared.

If there are already **0 active sessions**, the operation can move directly to **ReadyForAutomation** because there is nobody to wait for or log off.

### Timed grace period

For example, **1 hour** or **5 hours**.

Existing hosts are drained immediately so they receive no new sessions. Users who are already connected are allowed to continue working during the grace period.

- **Forced logoff OFF:** reaching the deadline does not mean an active user's session should simply be destroyed. The operation remains blocked until the remaining sessions have ended normally.
- **Forced logoff ON:** once the grace deadline is reached, remaining sessions are eligible for forced logoff. The operation can continue after those sessions have cleared.

If all users log off before the deadline, there is no reason to wait for the rest of the grace period; the operation can progress as soon as no sessions remain.

## Force logoff

The force-logoff setting only controls what happens to sessions that are still present when the workflow reaches the relevant deadline/logoff stage.

It does **not** mean that selecting a grace period automatically signs users out.

For an **Immediate** deployment, enabling it means remaining sessions may be forced off without a grace-period wait.

For a **timed** deployment, enabling it means remaining sessions may be forced off when the grace period expires.

Because forced logoff can interrupt users and cause unsaved work to be lost, it should be selected deliberately.

## Expected replacement outcomes

| Grace period | Force logoff | Active sessions | Expected behaviour |
| --- | --- | --- | --- |
| Immediate | Off | 0 | Drain hosts and progress immediately to the next stage. |
| Immediate | Off | 1+ | Drain hosts; do not force users off; wait for sessions to end normally. |
| Immediate | On | 0 | Drain hosts and progress immediately; no logoff is required. |
| Immediate | On | 1+ | Drain hosts; remaining sessions are eligible for immediate forced logoff; continue after sessions clear. |
| Timed | Off | 0 | Drain hosts and progress without waiting for the unused grace period. |
| Timed | Off | 1+ | Drain hosts; allow users to remain; after the deadline continue waiting until sessions end normally. |
| Timed | On | 0 | Drain hosts and progress without waiting for the unused grace period. |
| Timed | On | 1+ | Drain hosts; allow users to remain until the deadline; then force remaining sessions off and continue after they clear. |

## Deployment stages

**ReadyForAutomation** means the drain/session requirements have been satisfied and the operation is ready for the next Azure Automation stage.

While sessions remain during a timed grace period, the deployment should show the number of sessions remaining and the time remaining before the grace deadline.

## Cancelling a deployment

A deployment can be cancelled while cancellation is still available and before the Azure Automation deployment job has been submitted.

Cancellation restores the original session-host drain states. This is important because a host that was accepting sessions before the replacement workflow should return to that state when the pre-Automation operation is cancelled.

Once the Azure Automation deployment has been submitted, cancellation is no longer treated as a simple rollback of the pre-deployment drain operation.

## Multiple host pools

Deployments for different host pools are independent operations. This allows AVD Manager to manage deployments to a primary and secondary host pool at the same time without one pool's grace period or session state blocking the other.

## Settings → Advanced deployment defaults

AVD Manager should keep deployment infrastructure configuration out of the normal Deploy Hosts form. The recommended design is a **separate tile for each discovered host pool** under **Settings → Advanced deployment defaults**.

Each host-pool tile should show the discovered mappings and allow only the defaults/overrides that are genuinely pool-specific. Discovered resource relationships should be pre-filled and remain read-only unless the engineer deliberately chooses an override.

Recommended host-pool defaults:

- Join type: `ADDS` or `ENTRA`.
- Default VM size.
- Default gallery image definition and image version (`Latest` by default).
- Session-host resource group.
- Gallery resource group and gallery name.
- VNet resource group, VNet and subnet.
- Key Vault name.
- ADDS domain FQDN and OU path when Join type is ADDS.
- Install RDS role on Server OS toggle where required.
- Temporarily disable attached scaling plans during deployment.

Recommended environment-wide defaults, shared across host pools unless overridden:

- Local-admin username/password **secret names**.
- ADDS join username/password **secret names**.
- Entra tenant ID.
- Intune enrollment toggle and MDM ID.
- Environment tag used on newly created VMs.

Secret **values** must never be stored in AVD Manager deployment settings. Only Key Vault names and secret names are persisted; the Azure Automation managed identity reads the values at run time.

The normal Deploy Hosts page should stay focused on engineer choices: target host pool, VM prefix, host count, VM size, image/version, replacement mode, grace period and force-logoff policy.

## DeployAVDHosts runbook contract

The revised runbook is designed to be reusable across host pools rather than containing customer-specific resource names. AVD Manager supplies the selected host-pool mapping when the Automation job is created.

The runbook accepts the following main groups of parameters:

- Environment: subscription ID and location.
- Target: host pool name, host-pool resource group and session-host resource group.
- Deployment: VM prefix, host count, replace-existing flag and VM size.
- Image: gallery resource group, gallery name, image definition and image version.
- Network: VNet resource group, VNet and subnet.
- Security/join: Key Vault name, join type, secret names, domain/OU or Entra/Intune settings.
- Behaviour: temporary scaling-plan disable, Server OS RDS-role option and environment tag.

AVD Manager owns grace periods and forced logoff. The runbook deliberately has **no ForceLogoffUsers parameter**. Before destructive replacement it repeats a fail-closed live user-session check and refuses to delete any existing host while a user session remains.

The runbook also preflights the host pool, session-host resource group, network/subnet, image version, Key Vault credentials and AVD registration-token creation before deleting an existing session host. This reduces the chance of avoidable downtime caused by a bad mapping or missing permission.

## Suggested safe first test

For validating the grace-period path:

1. Start with an existing session host that is accepting connections.
2. Log a test user into the AVD desktop and leave the session connected.
3. Select **Replace existing session hosts**.
4. Select a short timed grace period, such as **1 hour**.
5. Leave **Force logoff** off.
6. Review and start the workflow.
7. Confirm the existing host enters drain mode.
8. Confirm the deployment reports **1 session remaining** and waits rather than moving immediately to ReadyForAutomation.
9. Confirm the grace countdown is displayed.
10. Log the test user off normally and confirm the operation can then progress.

This test validates draining, session detection, grace-period handling and normal user logoff without deliberately terminating a user session.
