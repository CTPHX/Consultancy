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
    public string? ErrorMessage { get; private set; }\n    public IReadOnlyList<string> VmSizes { get; private set; } = [];\n    public IReadOnlyList<AzureRegionOption> Regions { get; private set; } = [];

    public async Task OnGetAsync(CancellationToken cancellationToken)
    {
        Environment = await _store.GetAsync(cancellationToken);
        if (Environment is null) return;
        try
        {
            Discovery = await _images.DiscoverAsync(Environment.SubscriptionId, cancellationToken);\n            Regions = await _images.GetRegionsAsync(Environment.SubscriptionId, cancellationToken);\n            var defaultLocation = Discovery.VirtualMachines.FirstOrDefault()?.Location ?? Discovery.Galleries.FirstOrDefault()?.Location ?? "";\n            VmSizes = await _images.GetVmSizesAsync(Environment.SubscriptionId, defaultLocation, cancellationToken);
            if (Environment.ImageManagementDefaults is not null)
            {
                Build.VirtualNetworkId = Environment.ImageManagementDefaults.VirtualNetworkId;
                Build.SubnetName = Environment.ImageManagementDefaults.SubnetName;\n                Build.TempVmSize = Environment.ImageManagementDefaults.TemporaryVmSize;\n                Build.ReplicaCount = Environment.ImageManagementDefaults.ReplicaCount;\n                Build.TargetRegions = Environment.ImageManagementDefaults.TargetRegions?.ToList() ?? [];
            }
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }
    }

    public async Task<JsonResult> OnGetSubnetsAsync(string vnetId, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(vnetId)) return new JsonResult(Array.Empty<AzureSubnetOption>());
        var environment = await _store.GetAsync(cancellationToken);
        if (environment is null || !vnetId.StartsWith($"/subscriptions/{environment.SubscriptionId}/", StringComparison.OrdinalIgnoreCase))
            return new JsonResult(Array.Empty<AzureSubnetOption>());
        return new JsonResult(await _images.GetSubnetsAsync(vnetId, cancellationToken));
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
    public List<string> TargetRegions { get; set; } = [];
    public bool ExcludeFromLatest { get; set; }
}
