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

    public HostPoolModel(
        EnvironmentConfigurationStore environmentStore,
        HostPoolRefreshService hostPoolRefresh,
        HostPoolDetailService hostPoolDetail)
    {
        _environmentStore = environmentStore;
        _hostPoolRefresh = hostPoolRefresh;
        _hostPoolDetail = hostPoolDetail;
    }

    public EnvironmentConfiguration? EnvironmentConfiguration { get; private set; }
    public SavedHostPoolConfiguration? HostPool { get; private set; }
    public IReadOnlyList<string> ScalingPlans { get; private set; } = [];
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

    private static SavedHostPoolConfiguration? FindPool(EnvironmentConfiguration environment, string id) =>
        environment.HostPools.FirstOrDefault(pool =>
            pool.HostPoolName.Equals(id, StringComparison.OrdinalIgnoreCase) ||
            pool.HostPoolId.Equals(id, StringComparison.OrdinalIgnoreCase));
}
