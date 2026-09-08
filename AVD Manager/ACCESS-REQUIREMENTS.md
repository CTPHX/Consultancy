# AVD Manager — Access Requirements Ledger

This file records every Azure permission AVD Manager needs as features are implemented. During development we may temporarily use broader built-in roles for speed, but the production goal is to replace those with one or more least-privilege custom roles and narrowly scoped assignments.

## Development approach

- Temporary development shortcut: assign **Contributor** to the AVD Manager service identity at the narrowest practical scope needed to exercise write features.
- Current AVD test scope: `rg-avd-hosts-uks`.
- Do **not** assign Contributor at subscription scope unless a feature genuinely cannot be tested with a narrower assignment.
- The Azure Automation Account managed identity remains a separate privileged execution identity for complex runbooks and should not be changed just to satisfy web-app permissions.
- Before production, replace temporary broad assignments with least-privilege custom role definitions built from the permissions recorded below.

## Permissions observed so far

| Area | Feature | Azure resource provider action | Access type | Suggested production scope | Status / notes |
| --- | --- | --- | --- | --- | --- |
| ARM discovery | Subscription/resource discovery | Read access to subscription/resource metadata and discovered Azure resources | Read | Subscription or selected resource groups, depending on onboarding model | Currently satisfied by Reader during development. Keep discovery read-only where possible. |
| AVD | Read host pools/session hosts/application groups/scaling plans | `Microsoft.DesktopVirtualization/*/read` (to be narrowed to exact resource types before production) | Read | AVD resource group(s) | Used by discovery, host-pool details, live refresh and state reconciliation. |
| AVD | Single/bulk drain mode (`allowNewSession`) | `Microsoft.DesktopVirtualization/hostPools/sessionHosts/write` | Write | AVD host-pool resource group or narrower host-pool scope where practical | Required for the direct ARM drain-mode API. Development shortcut: Contributor on `rg-avd-hosts-uks`. |
| Compute | Read backing VM state/details | `Microsoft.Compute/virtualMachines/read` | Read | Session-host VM resource group(s) | Used to map AVD session hosts to backing Azure VMs. |
| Compute | Start selected session-host VMs | `Microsoft.Compute/virtualMachines/start/action` | Operational action | Session-host VM resource group(s), or specific VM scope where practical | AVD Manager service identity. Direct ARM POST to the backing VM `start` action. |
| Compute | Stop/deallocate selected session-host VMs | `Microsoft.Compute/virtualMachines/deallocate/action` | Operational action | Session-host VM resource group(s), or specific VM scope where practical | AVD Manager service identity. Direct ARM POST to `deallocate`; UI requires the selected AVD session host to be in drain mode first. |
| Network | Read NIC/VNet/subnet relationships | `Microsoft.Network/networkInterfaces/read`, `Microsoft.Network/virtualNetworks/read`, subnet read via VNet resource | Read | Network resource group(s) | Used by discovery/mapping only at present. |
| Compute Gallery | Read gallery/image/version relationships | Read access to Compute Gallery, image definitions and versions | Read | Image/gallery resource group(s) | Used by image discovery and host-pool detail display. Exact actions will be captured before production role creation. |
| Automation | Discover Automation Account/runbooks | Read access to Automation resources | Read | Automation resource group / Automation Account | Needed for discovery and later job views. No drain-mode Automation write permission is needed now. |
| Automation | Start approved operational runbooks | Exact Automation job/runbook actions **TBD when first complex operational workflow is wired up** | Write/read | Specific Automation Account | Do not grant broad Automation Contributor by default. Capture exact required actions during deployment/image/FSLogix implementation. |
| Key Vault | Discover mapped Key Vault resource | Resource metadata read only from ARM | Read | Key Vault resource group | The web app should not need secret-value access for current discovery. If a future feature requires secrets, record the data-plane permission separately. |
| Storage | Discover storage accounts / Azure Files metadata | Resource metadata read; exact storage data-plane actions TBD only if web app directly accesses shares | Read | Storage resource group / storage account | Existing PowerShell runbooks continue to use their own managed identity permissions. |

## Permissions to capture as features are added

For every new operational feature, record:

1. The exact Azure REST/SDK operation being called.
2. The corresponding Azure RBAC action(s), including any required read/check actions.
3. Whether the permission belongs to the **AVD Manager service identity** or the **Automation Account managed identity**.
4. The narrowest practical assignment scope.
5. Whether the action is read-only, operational write, destructive write, or data-plane access.
6. Any extra permissions discovered from real 403/authorization failures during testing.

Expected upcoming areas include VM restart, Azure Automation job submission/read/output, session management/logoff, session-host deployment, image management, storage/FSLogix operations and licensing/onboarding deployment tasks.

## Production custom-role goal

Before production:

- Review this ledger against the code paths actually enabled in the product.
- Remove permissions for abandoned or server-side-only features.
- Split read-only discovery from operational write permissions if that gives cleaner separation of duties.
- Create custom Azure role definition(s) using only the required `Actions` / `DataActions`.
- Scope assignments to customer environment resource groups or specific resources wherever practical.
- Add AVD Manager application roles so an authenticated user cannot exercise Azure write permissions merely because the backend identity has them.
- Re-test every supported operation under the custom role and use any authorization failures to refine the role before release.
