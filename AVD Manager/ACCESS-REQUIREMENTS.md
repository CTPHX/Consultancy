# AVD Manager — Access Requirements Ledger

This file records every Azure permission AVD Manager needs as features are implemented. Development may temporarily use broader built-in roles, but production will use least-privilege custom roles and narrow scopes.

## Development approach
- Temporary development shortcut: Contributor only at the narrowest practical scope required for write features.
- Current AVD test scope: `rg-avd-hosts-uks`; do not use subscription-wide Contributor unless genuinely required.
- Azure Automation Account managed identity remains the separate privileged execution identity for complex runbooks.
- Before production, replace broad assignments with custom roles built from this ledger.

## Permissions observed so far

| Area | Feature | Azure resource provider action | Access type | Suggested production scope | Status / notes |
| --- | --- | --- | --- | --- | --- |
| ARM discovery | Subscription/resource discovery | Read access to subscription/resource metadata | Read | Subscription or selected RGs | Reader currently satisfies development discovery. |
| AVD | Read host pools/session hosts/application groups/scaling plans | `Microsoft.DesktopVirtualization/*/read` (narrow later) | Read | AVD RG(s) | Discovery/details/reconciliation. |
| AVD | Read live user sessions | `Microsoft.DesktopVirtualization/hostPools/sessionHosts/userSessions/read` | Read | Host pool/RG | Required by UI and durable replacement safety checks. |
| AVD | Log off user session | `Microsoft.DesktopVirtualization/hostPools/sessionHosts/userSessions/delete` | Destructive write | Host pool/RG | Used only after explicit operator policy/confirmation; replacement workflow re-checks zero sessions afterwards. |
| AVD | Drain mode | `Microsoft.DesktopVirtualization/hostPools/sessionHosts/write` | Write | Host pool/RG | Required for direct ARM drain mode and replacement grace workflow. |
| AVD | Scaling plan association | `Microsoft.DesktopVirtualization/scalingPlans/write` | Write | Scaling plan/RG | Direct ARM scaling-plan state change. |
| Compute | Read VM | `Microsoft.Compute/virtualMachines/read` | Read | Session-host VM RG | Mapping/state. |
| Compute | Start VM | `Microsoft.Compute/virtualMachines/start/action` | Operational | VM/RG | Direct ARM. |
| Compute | Restart VM | `Microsoft.Compute/virtualMachines/restart/action` | Operational | VM/RG | Direct ARM; confirmation required. |
| Compute | Deallocate VM | `Microsoft.Compute/virtualMachines/deallocate/action` | Operational | VM/RG | Direct ARM; drain required. |
| Network | Read NIC/VNet/subnet | `Microsoft.Network/networkInterfaces/read`, `Microsoft.Network/virtualNetworks/read` | Read | Network RG | Discovery. |
| Compute Gallery | Read gallery/images/versions | Exact read actions TBD before production role creation | Read | Gallery RG | Image discovery/deployment selection. |
| Automation | Discover Automation Accounts | ARM resource read plus Automation Account read covered by discovery Reader during development | Read | Subscription for discovery, narrow after configuration | Settings lists only Automation Accounts discovered in the configured subscription. |
| Automation | Validate approved deployment runbook | `Microsoft.Automation/automationAccounts/runbooks/read` | Read | Selected Automation Account | Settings GETs the configured `DeployAVDHosts` runbook and requires state `Published` before saving. REST API currently uses `2024-10-23`. |
| Automation | Start approved runbook job | Exact job create/start action(s) to be verified when job submission is implemented | Write | Selected Automation Account | Do not grant Automation Contributor by default. Only `DeployAVDHosts` will be server-side allowlisted for this workflow. |
| Automation | Read job/status/streams | Exact job and stream read actions to be verified with submission implementation | Read | Selected Automation Account | Needed for durable Job ID/status/output tracking. |
| Key Vault | Discover mapped vault | Resource metadata read only | Read | Key Vault RG | Web app does not read secret values. |
| Storage | Discover storage metadata | Resource metadata read; data-plane TBD | Read | Storage RG/account | Runbooks retain their own MI permissions. |

## Permissions to capture as features are added
For every new operational feature record the exact REST/SDK operation, RBAC Actions/DataActions, identity, narrowest scope, access classification, and any permissions discovered from real 403 responses.

## Production custom-role goal
Before production, review actual enabled code paths, remove abandoned permissions, split discovery from operational rights where useful, create custom roles with only required Actions/DataActions, scope narrowly, add AVD Manager application roles, and re-test every supported operation under those roles.
