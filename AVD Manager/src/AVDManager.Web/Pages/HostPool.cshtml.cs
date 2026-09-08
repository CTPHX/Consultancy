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
    private readonly AzureVmOperationsService _vmOperations;

    public HostPoolModel(EnvironmentConfigurationStore environmentStore, HostPoolRefreshService hostPoolRefresh, HostPoolDetailService hostPoolDetail, AvdSessionHostOperationsService sessionHostOperations, AzureVmOperationsService vmOperations)
    {
        _environmentStore = environmentStore;
        _hostPoolRefresh = hostPoolRefresh;
        _hostPoolDetail = hostPoolDetail;
        _sessionHostOperations = sessionHostOperations;
        _vmOperations = vmOperations;
    }

    public EnvironmentConfiguration? EnvironmentConfiguration { get; private set; }
    public SavedHostPoolConfiguration? HostPool { get; private set; }
    public IReadOnlyList<ScalingPlanReference> ScalingPlans { get; private set; } = [];
    public string? ScalingPlanError { get; private set; }

    [TempData] public string? StatusMessage { get; set; }
    [TempData] public string? ErrorMessage { get; set; }

    public async Task<IActionResult> OnGetAsync(string id, CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null) return RedirectToPage("/Onboarding");
        var pool = FindPool(environment, id);
        if (pool is null) return NotFound();
        EnvironmentConfiguration = environment;
        HostPool = pool;
        try { ScalingPlans = await _hostPoolDetail.GetScalingPlansAsync(environment.SubscriptionId, pool.HostPoolId, cancellationToken); }
        catch (Exception ex) { ScalingPlanError = ex.Message; }
        return Page();
    }

    public async Task<IActionResult> OnPostRescanAsync(string id, CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null) return RedirectToPage("/Onboarding");
        var pool = FindPool(environment, id);
        if (pool is null) return NotFound();
        try
        {
            var updated = await _hostPoolRefresh.RefreshAsync(environment, pool.HostPoolId, cancellationToken);
            var refreshed = updated.HostPools.First(p => p.HostPoolId.Equals(pool.HostPoolId, StringComparison.OrdinalIgnoreCase));
            StatusMessage = $"Manual re-scan complete - {refreshed.SessionHosts.Count} session host(s) found.";
        }
        catch (Exception ex) { ErrorMessage = $"Could not re-scan host pool: {ex.Message}"; }
        return RedirectToPage(new { id = pool.HostPoolName });
    }

    public async Task<IActionResult> OnPostSetScalingPlanAsync(string id, string scalingPlanId, bool enabled, CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null) return RedirectToPage("/Onboarding");
        var pool = FindPool(environment, id);
        if (pool is null) return NotFound();

        try
        {
            var plans = await _hostPoolDetail.GetScalingPlansAsync(environment.SubscriptionId, pool.HostPoolId, cancellationToken);
            var plan = plans.FirstOrDefault(item => item.ResourceId.Equals(scalingPlanId, StringComparison.OrdinalIgnoreCase));
            if (plan is null)
            {
                ErrorMessage = "The selected scaling plan is no longer associated with this host pool. Refresh and try again.";
                return RedirectToPage(new { id = pool.HostPoolName });
            }

            await _hostPoolDetail.SetScalingPlanEnabledAsync(plan.ResourceId, pool.HostPoolId, enabled, cancellationToken);
            StatusMessage = $"Scaling plan {plan.Name} {(enabled ? "enabled" : "disabled")}.";
        }
        catch (Exception ex) { ErrorMessage = $"Could not update scaling plan: {ex.Message}"; }

        return RedirectToPage(new { id = pool.HostPoolName });
    }

    public async Task<IActionResult> OnPostSetDrainModeAsync(string id, List<string>? selectedSessionHosts, bool allowNewSession, CancellationToken cancellationToken)
    {
        var selection = await ResolveSelectionAsync(id, selectedSessionHosts, cancellationToken);
        if (selection.Result is not null) return selection.Result;
        var environment = selection.Environment!; var pool = selection.Pool!; var selectedHosts = selection.Hosts!;
        var hostPoolResourceGroup = GetResourceGroupFromArmId(pool.HostPoolId);
        if (string.IsNullOrWhiteSpace(hostPoolResourceGroup)) { ErrorMessage = "AVD Manager could not resolve the host pool resource group from its Azure resource ID."; return RedirectToPage(new { id = pool.HostPoolName }); }
        var succeeded = new List<string>(); var failures = new List<string>();
        foreach (var sessionHost in selectedHosts)
        {
            try { await _sessionHostOperations.SetAllowNewSessionAsync(environment.SubscriptionId, hostPoolResourceGroup, pool.HostPoolName, sessionHost.Name, allowNewSession, cancellationToken); succeeded.Add(sessionHost.Name); }
            catch (Exception ex) { failures.Add($"{sessionHost.Name}: {ex.Message}"); }
        }
        if (succeeded.Count > 0) { await TryRefreshAsync(environment, pool, cancellationToken); var state = allowNewSession ? "accept new sessions" : "enter drain mode"; StatusMessage = $"Updated {succeeded.Count} session host(s) to {state}."; }
        if (failures.Count > 0) ErrorMessage = $"{failures.Count} session host update(s) failed. {string.Join(" | ", failures)}";
        return RedirectToPage(new { id = pool.HostPoolName });
    }

    public Task<IActionResult> OnPostStartHostsAsync(string id, List<string>? selectedSessionHosts, CancellationToken cancellationToken) => SetVmPowerStateAsync(id, selectedSessionHosts, VmPowerAction.Start, cancellationToken);
    public Task<IActionResult> OnPostStopHostsAsync(string id, List<string>? selectedSessionHosts, CancellationToken cancellationToken) => SetVmPowerStateAsync(id, selectedSessionHosts, VmPowerAction.Stop, cancellationToken);
    public Task<IActionResult> OnPostRestartHostsAsync(string id, List<string>? selectedSessionHosts, CancellationToken cancellationToken) => SetVmPowerStateAsync(id, selectedSessionHosts, VmPowerAction.Restart, cancellationToken);

    private async Task<IActionResult> SetVmPowerStateAsync(string id, List<string>? selectedSessionHosts, VmPowerAction action, CancellationToken cancellationToken)
    {
        var selection = await ResolveSelectionAsync(id, selectedSessionHosts, cancellationToken);
        if (selection.Result is not null) return selection.Result;
        var environment = selection.Environment!; var pool = selection.Pool!; var selectedHosts = selection.Hosts!;
        if (action == VmPowerAction.Stop)
        {
            var notDraining = selectedHosts.Where(host => host.AllowNewSession != false).Select(host => host.Name).ToList();
            if (notDraining.Count > 0) { ErrorMessage = $"Put the selected host(s) into drain mode before stopping them: {string.Join(", ", notDraining)}."; return RedirectToPage(new { id = pool.HostPoolName }); }
        }
        var succeeded = new List<string>(); var failures = new List<string>();
        foreach (var sessionHost in selectedHosts)
        {
            if (string.IsNullOrWhiteSpace(sessionHost.VmName) || string.IsNullOrWhiteSpace(sessionHost.VmResourceGroup)) { failures.Add($"{sessionHost.Name}: backing Azure VM mapping is unavailable; re-scan the host pool and try again."); continue; }
            try
            {
                switch (action) { case VmPowerAction.Start: await _vmOperations.StartAsync(environment.SubscriptionId, sessionHost.VmResourceGroup, sessionHost.VmName, cancellationToken); break; case VmPowerAction.Stop: await _vmOperations.DeallocateAsync(environment.SubscriptionId, sessionHost.VmResourceGroup, sessionHost.VmName, cancellationToken); break; case VmPowerAction.Restart: await _vmOperations.RestartAsync(environment.SubscriptionId, sessionHost.VmResourceGroup, sessionHost.VmName, cancellationToken); break; }
                succeeded.Add(sessionHost.Name);
            }
            catch (Exception ex) { failures.Add($"{sessionHost.Name}: {ex.Message}"); }
        }
        if (succeeded.Count > 0)
        {
            await TryRefreshAsync(environment, pool, cancellationToken);
            StatusMessage = action switch { VmPowerAction.Start => $"Started {succeeded.Count} session host VM(s).", VmPowerAction.Stop => $"Stopped and deallocated {succeeded.Count} session host VM(s).", VmPowerAction.Restart => $"Restarted {succeeded.Count} session host VM(s).", _ => null };
        }
        if (failures.Count > 0) { var actionName = action.ToString().ToLowerInvariant(); ErrorMessage = $"{failures.Count} session host {actionName} operation(s) failed. {string.Join(" | ", failures)}"; }
        return RedirectToPage(new { id = pool.HostPoolName });
    }

    private async Task<(EnvironmentConfiguration? Environment, SavedHostPoolConfiguration? Pool, List<SavedSessionHost>? Hosts, IActionResult? Result)> ResolveSelectionAsync(string id, List<string>? selectedSessionHosts, CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null) return (null, null, null, RedirectToPage("/Onboarding"));
        var pool = FindPool(environment, id);
        if (pool is null) return (environment, null, null, NotFound());
        var requestedNames = (selectedSessionHosts ?? []).Where(name => !string.IsNullOrWhiteSpace(name)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (requestedNames.Count == 0) { ErrorMessage = "Select at least one session host first."; return (environment, pool, null, RedirectToPage(new { id = pool.HostPoolName })); }
        var selectedHosts = pool.SessionHosts.Where(host => requestedNames.Contains(host.Name, StringComparer.OrdinalIgnoreCase)).ToList();
        if (selectedHosts.Count != requestedNames.Count) { ErrorMessage = "One or more selected session hosts are no longer part of this host pool. Re-scan and try again."; return (environment, pool, null, RedirectToPage(new { id = pool.HostPoolName })); }
        return (environment, pool, selectedHosts, null);
    }

    private async Task TryRefreshAsync(EnvironmentConfiguration environment, SavedHostPoolConfiguration pool, CancellationToken cancellationToken)
    {
        try { await _hostPoolRefresh.RefreshAsync(environment, pool.HostPoolId, cancellationToken); } catch { }
    }

    private static SavedHostPoolConfiguration? FindPool(EnvironmentConfiguration environment, string id) => environment.HostPools.FirstOrDefault(pool => pool.HostPoolName.Equals(id, StringComparison.OrdinalIgnoreCase) || pool.HostPoolId.Equals(id, StringComparison.OrdinalIgnoreCase));
    private static string? GetResourceGroupFromArmId(string resourceId) { var parts = resourceId.Split('/', StringSplitOptions.RemoveEmptyEntries); for (var i = 0; i < parts.Length - 1; i++) if (parts[i].Equals("resourceGroups", StringComparison.OrdinalIgnoreCase)) return parts[i + 1]; return null; }
    private enum VmPowerAction { Start, Stop, Restart }
}
