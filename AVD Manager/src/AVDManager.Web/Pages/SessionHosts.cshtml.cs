using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class SessionHostsModel : PageModel
{
    private readonly EnvironmentConfigurationStore _environmentStore;

    public SessionHostsModel(EnvironmentConfigurationStore environmentStore)
    {
        _environmentStore = environmentStore;
    }

    public EnvironmentConfiguration? EnvironmentConfiguration { get; private set; }
    public IReadOnlyList<HostPoolGroup> HostPools { get; private set; } = [];
    public IReadOnlyList<SessionHostRow> SessionHosts => HostPools.SelectMany(p => p.SessionHosts).ToList();

    public async Task<IActionResult> OnGetAsync(CancellationToken cancellationToken)
    {
        EnvironmentConfiguration = await _environmentStore.GetAsync(cancellationToken);
        if (EnvironmentConfiguration is null)
            return RedirectToPage("/Onboarding");

        HostPools = EnvironmentConfiguration.HostPools
            .Select(pool => new HostPoolGroup(
                HostPoolName: pool.HostPoolName,
                HostPoolLocation: pool.Location,
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

        return Page();
    }
}

public sealed record HostPoolGroup(
    string HostPoolName,
    string HostPoolLocation,
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
