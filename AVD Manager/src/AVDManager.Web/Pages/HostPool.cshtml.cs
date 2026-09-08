using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class HostPoolModel : PageModel
{
    private const string DrainModeRunbookName = "Set-AVDSessionHostDrainMode";

    private readonly EnvironmentConfigurationStore _environmentStore;
    private readonly HostPoolRefreshService _hostPoolRefresh;
    private readonly HostPoolDetailService _hostPoolDetail;
    private readonly AzureAutomationService _azureAutomation;

    public HostPoolModel(
        EnvironmentConfigurationStore environmentStore,
        HostPoolRefreshService hostPoolRefresh,
        HostPoolDetailService hostPoolDetail,
        AzureAutomationService azureAutomation)
    {
        _environmentStore = environmentStore;
        _hostPoolRefresh = hostPoolRefresh;
        _hostPoolDetail = hostPoolDetail;
        _azureAutomation = azureAutomation;
    }

    public EnvironmentConfiguration? EnvironmentConfiguration { get; private set; }
    public SavedHostPoolConfiguration? HostPool { get; private set; }
    public IReadOnlyList<ScalingPlanReference> ScalingPlans { get; private set; } = [];
    public string? ScalingPlanError { get; private set; }

    [TempData]
    public string? StatusMessage { get; set; }

    [TempData]
    public string? ErrorMessage { get; set; }

    public async Task<IActionResult> OnGetAsync(string id, CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null)
            return RedirectToPage("/Onboarding");

        var pool = FindPool(environment, id);
        if (pool is null)
            return NotFound();

        EnvironmentConfiguration = environment;
        HostPool = pool;

        try
        {
            ScalingPlans = await _hostPoolDetail.GetScalingPlansAsync(environment.SubscriptionId, pool.HostPoolId, cancellationToken);
        }
        catch (Exception ex)
        {
            ScalingPlanError = ex.Message;
        }

        return Page();
    }

    public async Task<IActionResult> OnPostRescanAsync(string id, CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null)
            return RedirectToPage("/Onboarding");

        var pool = FindPool(environment, id);
        if (pool is null)
            return NotFound();

        try
        {
            var updated = await _hostPoolRefresh.RefreshAsync(environment, pool.HostPoolId, cancellationToken);
            var refreshed = updated.HostPools.First(p => p.HostPoolId.Equals(pool.HostPoolId, StringComparison.OrdinalIgnoreCase));
            StatusMessage = $"Manual re-scan complete - {refreshed.SessionHosts.Count} session host(s) found.";
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Could not re-scan host pool: {ex.Message}";
        }

        return RedirectToPage(new { id = pool.HostPoolName });
    }

    public async Task<IActionResult> OnPostSetDrainModeAsync(
        string id,
        string sessionHostName,
        bool allowNewSession,
        CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null)
            return RedirectToPage("/Onboarding");

        var pool = FindPool(environment, id);
        if (pool is null)
            return NotFound();

        var sessionHost = pool.SessionHosts.FirstOrDefault(host =>
            host.Name.Equals(sessionHostName, StringComparison.OrdinalIgnoreCase));

        if (sessionHost is null)
        {
            ErrorMessage = "The selected session host is not part of this saved host pool. Re-scan the host pool and try again.";
            return RedirectToPage(new { id = pool.HostPoolName });
        }

        if (string.IsNullOrWhiteSpace(pool.ResourceGroups.Automation))
        {
            ErrorMessage = "This host pool does not have an Automation resource group configured.";
            return RedirectToPage(new { id = pool.HostPoolName });
        }

        var hostPoolResourceGroup = GetResourceGroupFromArmId(pool.HostPoolId);
        if (string.IsNullOrWhiteSpace(hostPoolResourceGroup))
        {
            ErrorMessage = "AVD Manager could not resolve the host pool resource group from its Azure resource ID.";
            return RedirectToPage(new { id = pool.HostPoolName });
        }

        try
        {
            var job = await _azureAutomation.StartRunbookAsync(
                environment.SubscriptionId,
                pool.ResourceGroups.Automation,
                DrainModeRunbookName,
                new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["SubscriptionId"] = environment.SubscriptionId,
                    ["ResourceGroupName"] = hostPoolResourceGroup,
                    ["HostPoolName"] = pool.HostPoolName,
                    ["SessionHostName"] = sessionHost.Name,
                    ["AllowNewSession"] = allowNewSession ? "true" : "false"
                },
                cancellationToken);

            var requestedState = allowNewSession ? "accept new sessions" : "enter drain mode";
            StatusMessage = $"Requested {sessionHost.Name} to {requestedState}. Automation job {job.JobName} submitted.";
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Could not submit drain mode change: {ex.Message}";
        }

        return RedirectToPage(new { id = pool.HostPoolName });
    }

    private static SavedHostPoolConfiguration? FindPool(EnvironmentConfiguration environment, string id) =>
        environment.HostPools.FirstOrDefault(pool =>
            pool.HostPoolName.Equals(id, StringComparison.OrdinalIgnoreCase) ||
            pool.HostPoolId.Equals(id, StringComparison.OrdinalIgnoreCase));

    private static string? GetResourceGroupFromArmId(string resourceId)
    {
        var parts = resourceId.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
        {
            if (parts[i].Equals("resourceGroups", StringComparison.OrdinalIgnoreCase))
                return parts[i + 1];
        }

        return null;
    }
}
