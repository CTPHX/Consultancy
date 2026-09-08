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
    public IReadOnlyList<SessionHostRow> SessionHosts { get; private set; } = [];

    public async Task<IActionResult> OnGetAsync(CancellationToken cancellationToken)
    {
        EnvironmentConfiguration = await _environmentStore.GetAsync(cancellationToken);
        if (EnvironmentConfiguration is null)
            return RedirectToPage("/Onboarding");

        SessionHosts = EnvironmentConfiguration.HostPools
            .SelectMany(pool => pool.SessionHosts.Select(host => new SessionHostRow(
                HostPoolName: pool.HostPoolName,
                HostPoolLocation: pool.Location,
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
                ImageVersion: host.ImageVersion)))
            .OrderBy(h => h.HostPoolName)
            .ThenBy(h => h.Name)
            .ToList();

        return Page();
    }
}

public sealed record SessionHostRow(
    string HostPoolName,
    string HostPoolLocation,
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
