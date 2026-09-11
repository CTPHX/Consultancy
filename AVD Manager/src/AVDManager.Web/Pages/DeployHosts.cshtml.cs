using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using System.Text.RegularExpressions;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class DeployHostsModel : PageModel
{
    private static readonly string[] ActiveStatuses = ["Starting", "Draining", "WaitingForSessions", "ReadyForAutomation"];

    private readonly EnvironmentConfigurationStore _environmentStore;
    private readonly DeploymentOperationStore _operationStore;
    private readonly HostPoolRefreshService _hostPoolRefresh;
    private readonly AvdSessionHostOperationsService _sessionHostOperations;
    private readonly AvdUserSessionService _userSessionService;

    public DeployHostsModel(
        EnvironmentConfigurationStore environmentStore,
        DeploymentOperationStore operationStore,
        HostPoolRefreshService hostPoolRefresh,
        AvdSessionHostOperationsService sessionHostOperations,
        AvdUserSessionService userSessionService)
    {
        _environmentStore = environmentStore;
        _operationStore = operationStore;
        _hostPoolRefresh = hostPoolRefresh;
        _sessionHostOperations = sessionHostOperations;
        _userSessionService = userSessionService;
    }

    public EnvironmentConfiguration? EnvironmentConfiguration { get; private set; }
    public IReadOnlyList<DeployHostPoolOption> HostPools { get; private set; } = [];
    public IReadOnlyList<DeploymentOperation> Operations { get; private set; } = [];
    public SavedAutomationConfiguration? Automation => EnvironmentConfiguration?.Automation;

    [BindProperty] public string HostPoolId { get; set; } = string.Empty;
    [BindProperty] public string VmNamePrefix { get; set; } = string.Empty;
    [BindProperty] public int SessionHostCount { get; set; } = 1;
    [BindProperty] public string VmSize { get; set; } = "Standard_D2ds_v6";
    [BindProperty] public string GalleryImageVersion { get; set; } = "Latest";
    [BindProperty] public bool ReplaceExisting { get; set; }
    [BindProperty] public int GracePeriodHours { get; set; } = 5;
    [BindProperty] public bool ForceLogoffAtDeadline { get; set; }

    [TempData] public string? StatusMessage { get; set; }
    [TempData] public string? ErrorMessage { get; set; }

    public async Task<IActionResult> OnGetAsync(CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null) return RedirectToPage("/Onboarding");
        await LoadAsync(environment, cancellationToken);
        return Page();
    }

    public async Task<IActionResult> OnPostBeginAsync(CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null) return RedirectToPage("/Onboarding");
        if (environment.Automation is null)
        {
            ErrorMessage = "Configure and validate Azure Automation in Settings before beginning a deployment workflow.";
            return RedirectToPage();
        }

        var pool = environment.HostPools.FirstOrDefault(p => p.HostPoolId.Equals(HostPoolId, StringComparison.OrdinalIgnoreCase));
        if (pool is null)
        {
            ErrorMessage = "The selected host pool is no longer part of the saved environment.";
            return RedirectToPage();
        }

        var validationError = ValidateRequest();
        if (validationError is not null)
        {
            ErrorMessage = validationError;
            return RedirectToPage();
        }

        var existingOperations = await _operationStore.ListAsync(cancellationToken);
        if (existingOperations.Any(o =>
            o.HostPoolId.Equals(pool.HostPoolId, StringComparison.OrdinalIgnoreCase) &&
            ActiveStatuses.Contains(o.Status, StringComparer.OrdinalIgnoreCase)))
        {
            ErrorMessage = "This host pool already has an active deployment workflow. Complete or resolve that operation before starting another.";
            return RedirectToPage();
        }

        var hostPoolResourceGroup = GetResourceGroupFromArmId(pool.HostPoolId);
        if (string.IsNullOrWhiteSpace(hostPoolResourceGroup))
        {
            ErrorMessage = "AVD Manager could not resolve the host pool resource group.";
            return RedirectToPage();
        }

        var now = DateTimeOffset.UtcNow;
        var operation = new DeploymentOperation(
            Guid.NewGuid(), now, now, "Starting", environment.SubscriptionId, pool.HostPoolId, pool.HostPoolName,
            hostPoolResourceGroup, VmNamePrefix.Trim(), SessionHostCount, VmSize.Trim(), GalleryImageVersion.Trim(),
            ReplaceExisting, ReplaceExisting ? GracePeriodHours : 0, ReplaceExisting && ForceLogoffAtDeadline,
            ReplaceExisting ? now.AddHours(GracePeriodHours) : null, 0, null, null,
            "Deployment workflow created. No Azure Automation job has been submitted.", null);

        await _operationStore.AddAsync(operation, cancellationToken);

        try
        {
            if (!ReplaceExisting)
            {
                operation = operation with
                {
                    UpdatedAtUtc = DateTimeOffset.UtcNow,
                    Status = "ReadyForAutomation",
                    LastMessage = "Deployment request is validated and ready for Azure Automation submission. Submission is intentionally not enabled in this test stage."
                };
                await _operationStore.UpdateAsync(operation, cancellationToken);
                StatusMessage = "Deployment workflow created and ready for the next Automation stage.";
                return RedirectToPage();
            }

            var refreshedEnvironment = await _hostPoolRefresh.RefreshAsync(environment, pool.HostPoolId, cancellationToken);
            pool = refreshedEnvironment.HostPools.First(p => p.HostPoolId.Equals(pool.HostPoolId, StringComparison.OrdinalIgnoreCase));

            operation = operation with
            {
                UpdatedAtUtc = DateTimeOffset.UtcNow,
                Status = "Draining",
                LastMessage = $"Putting {pool.SessionHosts.Count} existing session host(s) into drain mode."
            };
            await _operationStore.UpdateAsync(operation, cancellationToken);

            var failures = new List<string>();
            foreach (var host in pool.SessionHosts)
            {
                try
                {
                    await _sessionHostOperations.SetAllowNewSessionAsync(
                        environment.SubscriptionId, hostPoolResourceGroup, pool.HostPoolName, host.Name, false, cancellationToken);
                }
                catch (Exception ex)
                {
                    failures.Add($"{host.Name}: {ex.Message}");
                }
            }

            if (failures.Count > 0)
                throw new InvalidOperationException($"Could not place all session hosts into drain mode. {string.Join(" | ", failures)}");

            var sessions = await _userSessionService.ListByHostPoolAsync(
                environment.SubscriptionId, hostPoolResourceGroup, pool.HostPoolName, cancellationToken);

            var activeCount = sessions.Count;
            operation = operation with
            {
                UpdatedAtUtc = DateTimeOffset.UtcNow,
                ActiveSessionCount = activeCount,
                Status = activeCount == 0 ? "ReadyForAutomation" : "WaitingForSessions",
                LastMessage = activeCount == 0
                    ? "All existing hosts are drained and no user sessions remain. The operation is ready for the next Automation stage."
                    : $"{activeCount} user session(s) remain. Hosts are drained and the grace period is running."
            };
            await _operationStore.UpdateAsync(operation, cancellationToken);

            StatusMessage = activeCount == 0
                ? "Drain complete. No user sessions remain."
                : $"Drain complete. Waiting for {activeCount} user session(s) to log off.";
        }
        catch (Exception ex)
        {
            operation = operation with
            {
                UpdatedAtUtc = DateTimeOffset.UtcNow,
                Status = "Failed",
                ErrorMessage = ex.Message,
                LastMessage = "The workflow stopped before any Azure Automation deployment job was submitted."
            };
            await _operationStore.UpdateAsync(operation, cancellationToken);
            ErrorMessage = $"Deployment workflow could not start safely: {ex.Message}";
        }

        return RedirectToPage();
    }

    public async Task<IActionResult> OnPostCancelAsync(Guid operationId, CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null) return RedirectToPage("/Onboarding");

        var operation = (await _operationStore.ListAsync(cancellationToken))
            .FirstOrDefault(o => o.Id == operationId);

        if (operation is null)
        {
            ErrorMessage = "The deployment operation no longer exists.";
            return RedirectToPage();
        }

        if (!ActiveStatuses.Contains(operation.Status, StringComparer.OrdinalIgnoreCase))
        {
            ErrorMessage = "This deployment workflow is no longer active.";
            return RedirectToPage();
        }

        try
        {
            foreach (var host in operation.OriginalHostStates ?? [])
            {
                await _sessionHostOperations.SetAllowNewSessionAsync(
                    operation.SubscriptionId,
                    operation.HostPoolResourceGroup,
                    operation.HostPoolName,
                    host.SessionHostName,
                    host.AllowNewSession,
                    cancellationToken);
            }

            await _operationStore.UpdateAsync(operation with
            {
                UpdatedAtUtc = DateTimeOffset.UtcNow,
                Status = "Cancelled",
                LastMessage = "Workflow cancelled. Original session-host drain states were restored.",
                ErrorMessage = null
            }, cancellationToken);

            StatusMessage = "Deployment workflow cancelled and original drain states restored.";
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Could not safely cancel the workflow: {ex.Message}";
        }

        return RedirectToPage();
    }

    public async Task<IActionResult> OnPostCheckSessionsAsync(Guid operationId, CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null) return RedirectToPage("/Onboarding");

        var operations = await _operationStore.ListAsync(cancellationToken);
        var operation = operations.FirstOrDefault(o => o.Id == operationId);
        if (operation is null)
        {
            ErrorMessage = "The deployment operation no longer exists.";
            return RedirectToPage();
        }

        if (!operation.ReplaceExisting || !ActiveStatuses.Contains(operation.Status, StringComparer.OrdinalIgnoreCase))
        {
            ErrorMessage = "This deployment operation is not waiting for replacement-session checks.";
            return RedirectToPage();
        }

        try
        {
            var sessions = await _userSessionService.ListByHostPoolAsync(
                environment.SubscriptionId, operation.HostPoolResourceGroup, operation.HostPoolName, cancellationToken);
            var count = sessions.Count;
            var deadlineExpired = operation.GraceDeadlineUtc is not null && DateTimeOffset.UtcNow >= operation.GraceDeadlineUtc.Value;

            var status = count == 0 ? "ReadyForAutomation" : "WaitingForSessions";
            var message = count == 0
                ? "No user sessions remain. The operation is ready for the next Automation stage."
                : deadlineExpired
                    ? operation.ForceLogoffAtDeadline
                        ? $"{count} user session(s) remain and the grace deadline has expired. Forced logoff is configured but is intentionally not executed in this test stage."
                        : $"{count} user session(s) remain and the grace deadline has expired. The operation will not proceed automatically."
                    : $"{count} user session(s) remain. The grace period is still running.";

            await _operationStore.UpdateAsync(operation with
            {
                UpdatedAtUtc = DateTimeOffset.UtcNow,
                ActiveSessionCount = count,
                Status = status,
                LastMessage = message
            }, cancellationToken);

            StatusMessage = count == 0 ? "Session check complete. No users remain." : $"Session check complete. {count} user session(s) remain.";
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Could not refresh live user sessions: {ex.Message}";
        }

        return RedirectToPage();
    }

    private async Task LoadAsync(EnvironmentConfiguration environment, CancellationToken cancellationToken)
    {
        EnvironmentConfiguration = environment;
        HostPools = environment.HostPools.OrderBy(pool => pool.HostPoolName, StringComparer.OrdinalIgnoreCase).Select(BuildHostPoolOption).ToList();
        Operations = (await _operationStore.ListAsync(cancellationToken)).Take(10).ToList();
    }

    private string? ValidateRequest()
    {
        if (string.IsNullOrWhiteSpace(VmNamePrefix)) return "Enter a VM name prefix.";
        if (VmNamePrefix.Length > 12) return "VM name prefix must be 12 characters or fewer.";
        if (!Regex.IsMatch(VmNamePrefix, @"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"))
            return "VM name prefix may contain letters, numbers and hyphens only, and cannot begin or end with a hyphen.";
        if (SessionHostCount is < 1 or > 20) return "Number of hosts must be between 1 and 20.";
        if (string.IsNullOrWhiteSpace(VmSize)) return "VM size is required.";
        if (string.IsNullOrWhiteSpace(GalleryImageVersion)) return "Gallery image version is required.";
        if (ReplaceExisting && GracePeriodHours is < 0 or > 24) return "Grace period must be Immediate or between 1 and 24 hours.";
        return null;
    }

    private static DeployHostPoolOption BuildHostPoolOption(SavedHostPoolConfiguration pool)
    {
        var mappedHost = pool.SessionHosts.OrderByDescending(host => !string.IsNullOrWhiteSpace(host.ImageVersion)).ThenBy(host => host.Name, StringComparer.OrdinalIgnoreCase).FirstOrDefault();
        return new DeployHostPoolOption(pool.HostPoolId, pool.HostPoolName, pool.Location, pool.SessionHosts.Count,
            SuggestVmPrefix(mappedHost?.VmName), pool.ResourceGroups.Avd, pool.ResourceGroups.SessionHosts,
            pool.ResourceGroups.Network, pool.ResourceGroups.Gallery, pool.ResourceGroups.Automation,
            mappedHost?.VnetName, mappedHost?.SubnetName, mappedHost?.GalleryName, mappedHost?.ImageDefinition, mappedHost?.ImageVersion);
    }

    private static string SuggestVmPrefix(string? vmName)
    {
        if (string.IsNullOrWhiteSpace(vmName)) return string.Empty;
        var withoutNumber = Regex.Replace(vmName, @"\d+$", string.Empty).TrimEnd('-', '_');
        return string.IsNullOrWhiteSpace(withoutNumber) ? vmName : withoutNumber;
    }

    private static string? GetResourceGroupFromArmId(string resourceId)
    {
        var parts = resourceId.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
            if (parts[i].Equals("resourceGroups", StringComparison.OrdinalIgnoreCase)) return parts[i + 1];
        return null;
    }
}

public sealed record DeployHostPoolOption(string HostPoolId, string HostPoolName, string Location, int ExistingHostCount,
    string SuggestedVmPrefix, string? AvdResourceGroup, string? SessionHostResourceGroup, string? NetworkResourceGroup,
    string? GalleryResourceGroup, string? AutomationResourceGroup, string? VnetName, string? SubnetName,
    string? GalleryName, string? ImageDefinition, string? ImageVersion);
