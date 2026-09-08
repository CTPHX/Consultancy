using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class HostPoolModel : PageModel
{
    private readonly EnvironmentConfigurationStore _environmentStore;
    private readonly HostPoolRefreshService _hostPoolRefresh;
    private readonly HostPoolDetailService _hostPoolDetail;
    private readonly AvdSessionHostOperationsService _sessionHostOperations;

    public HostPoolModel(
        EnvironmentConfigurationStore environmentStore,
        HostPoolRefreshService hostPoolRefresh,
        HostPoolDetailService hostPoolDetail,
        AvdSessionHostOperationsService sessionHostOperations)
    {
        _environmentStore = environmentStore;
        _hostPoolRefresh = hostPoolRefresh;
        _hostPoolDetail = hostPoolDetail;
        _sessionHostOperations = sessionHostOperations;
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
        List<string>? selectedSessionHosts,
        bool allowNewSession,
        CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null)
            return RedirectToPage("/Onboarding");

        var pool = FindPool(environment, id);
        if (pool is null)
            return NotFound();

        var requestedNames = (selectedSessionHosts ?? [])
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (requestedNames.Count == 0)
        {
            ErrorMessage = "Select at least one session host first.";
            return RedirectToPage(new { id = pool.HostPoolName });
        }

        var selectedHosts = pool.SessionHosts
            .Where(host => requestedNames.Contains(host.Name, StringComparer.OrdinalIgnoreCase))
            .ToList();

        if (selectedHosts.Count != requestedNames.Count)
        {
            ErrorMessage = "One or more selected session hosts are no longer part of this host pool. Re-scan and try again.";
            return RedirectToPage(new { id = pool.HostPoolName });
        }

        var hostPoolResourceGroup = GetResourceGroupFromArmId(pool.HostPoolId);
        if (string.IsNullOrWhiteSpace(hostPoolResourceGroup))
        {
            ErrorMessage = "AVD Manager could not resolve the host pool resource group from its Azure resource ID.";
            return RedirectToPage(new { id = pool.HostPoolName });
        }

        var succeeded = new List<string>();
        var failures = new List<string>();

        foreach (var sessionHost in selectedHosts)
        {
            try
            {
                await _sessionHostOperations.SetAllowNewSessionAsync(
                    environment.SubscriptionId,
                    hostPoolResourceGroup,
                    pool.HostPoolName,
                    sessionHost.Name,
                    allowNewSession,
                    cancellationToken);
                succeeded.Add(sessionHost.Name);
            }
            catch (Exception ex)
            {
                failures.Add($"{sessionHost.Name}: {ex.Message}");
            }
        }

        if (succeeded.Count > 0)
        {
            try
            {
                await _hostPoolRefresh.RefreshAsync(environment, pool.HostPoolId, cancellationToken);
            }
            catch
            {
                // The Azure update already succeeded. The normal live refresh can reconcile display state.
            }

            var state = allowNewSession ? "accept new sessions" : "enter drain mode";
            StatusMessage = $"Updated {succeeded.Count} session host(s) to {state}.";
        }

        if (failures.Count > 0)
            ErrorMessage = $"{failures.Count} session host update(s) failed. {string.Join(" | ", failures)}";

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
