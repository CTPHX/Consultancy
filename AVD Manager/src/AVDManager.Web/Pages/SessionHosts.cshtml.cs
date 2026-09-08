using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class SessionHostsModel : PageModel
{
    private readonly EnvironmentConfigurationStore _environmentStore;
    private readonly HostPoolRefreshService _hostPoolRefresh;

    public SessionHostsModel(
        EnvironmentConfigurationStore environmentStore,
        HostPoolRefreshService hostPoolRefresh)
    {
        _environmentStore = environmentStore;
        _hostPoolRefresh = hostPoolRefresh;
    }

    public EnvironmentConfiguration? EnvironmentConfiguration { get; private set; }
    public IReadOnlyList<HostPoolGroup> HostPools { get; private set; } = [];
    public IReadOnlyList<SessionHostRow> SessionHosts => HostPools.SelectMany(p => p.SessionHosts).ToList();

    [TempData]
    public string? StatusMessage { get; set; }

    [TempData]
    public string? ErrorMessage { get; set; }

    public async Task<IActionResult> OnGetAsync(CancellationToken cancellationToken)
    {
        EnvironmentConfiguration = await _environmentStore.GetAsync(cancellationToken);
        if (EnvironmentConfiguration is null)
            return RedirectToPage("/Onboarding");

        BuildViewModel(EnvironmentConfiguration);
        return Page();
    }

    public async Task<IActionResult> OnPostRescanHostPoolAsync(string hostPoolId, CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null)
            return RedirectToPage("/Onboarding");

        var pool = environment.HostPools.FirstOrDefault(p =>
            p.HostPoolId.Equals(hostPoolId, StringComparison.OrdinalIgnoreCase));

        if (pool is null)
        {
            ErrorMessage = "The selected host pool is not part of the saved environment.";
            return RedirectToPage();
        }

        try
        {
            var updated = await _hostPoolRefresh.RefreshAsync(environment, hostPoolId, cancellationToken);
            var refreshed = updated.HostPools.First(p => p.HostPoolId.Equals(hostPoolId, StringComparison.OrdinalIgnoreCase));
            StatusMessage = $"{refreshed.HostPoolName} re-scanned. {refreshed.SessionHosts.Count} session host(s) found.";
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Could not re-scan {pool.HostPoolName}: {ex.Message}";
        }

        return RedirectToPage();
    }

    private void BuildViewModel(EnvironmentConfiguration environment)
    {
        EnvironmentConfiguration = environment;
        HostPools = environment.HostPools
            .Select(pool => new HostPoolGroup(
                HostPoolId: pool.HostPoolId,
                HostPoolName: pool.HostPoolName,
                HostPoolLocation: pool.Location,
                LastScannedAtUtc: pool.LastScannedAtUtc ?? environment.LastScannedAtUtc,
                SessionHosts: pool.SessionHosts
                    .Select(host => new SessionHostRow(
                        Name: host.Name,
                        Status: host.Status,
                        AllowNewSession: host.AllowNewSession,
                        Sessions: host.Sessions ?? 0,
                        VmName: host.VmName,
                        VmResourceGroup: host.VmResourceGroup,
                        NicName: host.NicName,
                        VnetName: host.VnetName,
                        SubnetName: host.SubnetName,
                        GalleryName: host.GalleryName,
                        ImageDefinition: host.ImageDefinition,
                        ImageVersion: host.ImageVersion))
                    .OrderBy(h => h.Name)
                    .ToList()))
            .OrderBy(p => p.HostPoolName)
            .ToList();
    }
}

public sealed record HostPoolGroup(
    string HostPoolId,
    string HostPoolName,
    string HostPoolLocation,
    DateTimeOffset LastScannedAtUtc,
    IReadOnlyList<SessionHostRow> SessionHosts)
{
    public int AvailableHosts => SessionHosts.Count(h => string.Equals(h.Status, "Available", StringComparison.OrdinalIgnoreCase));
    public int UnavailableHosts => SessionHosts.Count - AvailableHosts;
    public int ActiveSessions => SessionHosts.Sum(h => h.Sessions);
}

public sealed record SessionHostRow(
    string Name,
    string? Status,
    bool? AllowNewSession,
    int Sessions,
    string? VmName,
    string? VmResourceGroup,
    string? NicName,
    string? VnetName,
    string? SubnetName,
    string? GalleryName,
    string? ImageDefinition,
    string? ImageVersion);
