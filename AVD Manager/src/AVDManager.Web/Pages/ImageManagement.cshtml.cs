using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class ImageManagementModel : PageModel
{
    private readonly EnvironmentConfigurationStore _store;
    private readonly AzureImageManagementService _images;

    public ImageManagementModel(EnvironmentConfigurationStore store, AzureImageManagementService images)
    {
        _store = store;
        _images = images;
    }

    [BindProperty] public ImageBuildInput Build { get; set; } = new();
    public EnvironmentConfiguration? Environment { get; private set; }
    public ImageManagementDiscovery? Discovery { get; private set; }
    public string? ErrorMessage { get; private set; }

    public async Task OnGetAsync(CancellationToken cancellationToken)
    {
        Environment = await _store.GetAsync(cancellationToken);
        if (Environment is null) return;
        try { Discovery = await _images.DiscoverAsync(Environment.SubscriptionId, cancellationToken); }
        catch (Exception ex) { ErrorMessage = ex.Message; }
    }

    public string ProposedVersion(string gallery, string definition)
    {
        var versions = Discovery?.Versions
            .Where(x => x.GalleryName.Equals(gallery, StringComparison.OrdinalIgnoreCase) && x.DefinitionName.Equals(definition, StringComparison.OrdinalIgnoreCase))
            .Select(x => Version.TryParse(x.Name, out var v) ? v : null)
            .Where(x => x is not null).Cast<Version>().OrderBy(x => x).ToList() ?? [];
        if (versions.Count == 0) return "0.0.1";
        var v = versions[^1];
        return $"{v.Major}.{v.Minor}.{v.Build + 1}";
    }
}

public sealed class ImageBuildInput
{
    public string GoldVmId { get; set; } = "";
    public string GalleryId { get; set; } = "";
    public string ImageDefinitionId { get; set; } = "";
    public string ImageVersion { get; set; } = "";
    public string VirtualNetworkId { get; set; } = "";
    public string SubnetName { get; set; } = "";
    public string TempVmSize { get; set; } = "Standard_D2ds_v6";
    public int ReplicaCount { get; set; } = 1;
    public string TargetRegions { get; set; } = "";
    public bool ExcludeFromLatest { get; set; }
}
