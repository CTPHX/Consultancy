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
    public IReadOnlyList<string> VmSizes { get; private set; } = [];
    public IReadOnlyList<AzureRegionOption> Regions { get; private set; } = [];
    public ImageBuildReview? Review { get; private set; }

    public async Task OnGetAsync(CancellationToken cancellationToken)
    {
        Environment = await _store.GetAsync(cancellationToken);
        if (Environment is null) return;
        try
        {
            Discovery = await _images.DiscoverAsync(Environment.SubscriptionId, cancellationToken);
            Regions = await _images.GetRegionsAsync(Environment.SubscriptionId, cancellationToken);
            var defaultLocation = Discovery.VirtualMachines.FirstOrDefault()?.Location ?? Discovery.Galleries.FirstOrDefault()?.Location ?? "";
            VmSizes = await _images.GetVmSizesAsync(Environment.SubscriptionId, defaultLocation, cancellationToken);
            if (Environment.ImageManagementDefaults is not null)
            {
                Build.VirtualNetworkId = Environment.ImageManagementDefaults.VirtualNetworkId;
                Build.SubnetName = Environment.ImageManagementDefaults.SubnetName;
                Build.TempVmSize = Environment.ImageManagementDefaults.TemporaryVmSize;
                Build.ReplicaCount = Environment.ImageManagementDefaults.ReplicaCount;
                Build.TargetRegions = Environment.ImageManagementDefaults.TargetRegions?.ToList() ?? [];
            }
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }
    }

    public async Task<IActionResult> OnPostReviewAsync(CancellationToken cancellationToken)
    {
        Environment = await _store.GetAsync(cancellationToken);
        if (Environment is null) return Page();

        try
        {
            Discovery = await _images.DiscoverAsync(Environment.SubscriptionId, cancellationToken);
            Regions = await _images.GetRegionsAsync(Environment.SubscriptionId, cancellationToken);

            var vm = Discovery.VirtualMachines.FirstOrDefault(x => x.Id.Equals(Build.GoldVmId, StringComparison.OrdinalIgnoreCase));
            var gallery = Discovery.Galleries.FirstOrDefault(x => x.Id.Equals(Build.GalleryId, StringComparison.OrdinalIgnoreCase));
            var definition = Discovery.Definitions.FirstOrDefault(x => x.Id.Equals(Build.ImageDefinitionId, StringComparison.OrdinalIgnoreCase));
            var vnet = Discovery.VirtualNetworks.FirstOrDefault(x => x.Id.Equals(Build.VirtualNetworkId, StringComparison.OrdinalIgnoreCase));

            if (vm is null || gallery is null || definition is null || vnet is null)
                throw new InvalidOperationException("One or more selected Azure resources could not be resolved. Refresh the page and review the selections.");

            var subnets = await _images.GetSubnetsAsync(vnet.Id, cancellationToken);
            if (!subnets.Any(x => x.Name.Equals(Build.SubnetName, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("The selected subnet could not be resolved in the selected virtual network.");

            var defaultLocation = vm.Location;
            VmSizes = await _images.GetVmSizesAsync(Environment.SubscriptionId, defaultLocation, cancellationToken);
            if (!VmSizes.Contains(Build.TempVmSize, StringComparer.OrdinalIgnoreCase))
                throw new InvalidOperationException($"VM size '{Build.TempVmSize}' is not available in {defaultLocation}.");

            if (Build.ReplicaCount < 1 || Build.ReplicaCount > 10)
                throw new InvalidOperationException("Replica count must be between 1 and 10.");
            if (Build.TargetRegions.Count == 0)
                throw new InvalidOperationException("Select at least one target region.");
            if (!Version.TryParse(Build.ImageVersion, out _))
                throw new InvalidOperationException("Enter a valid image version such as 0.0.2.");
            if (Discovery.Versions.Any(x => x.Id.Equals($"{definition.Id.TrimEnd('/')}/versions/{Build.ImageVersion}", StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException($"Image version {Build.ImageVersion} already exists in {definition.Name}.");

            Review = new ImageBuildReview(vm.Name, gallery.Name, definition.Name, Build.ImageVersion, vnet.Name,
                Build.SubnetName, Build.TempVmSize, Build.ReplicaCount, Build.TargetRegions, Build.ExcludeFromLatest);
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }

        return Page();
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

public sealed record ImageBuildReview(string GoldVmName, string GalleryName, string DefinitionName, string ImageVersion,
    string VirtualNetworkName, string SubnetName, string TempVmSize, int ReplicaCount,
    IReadOnlyList<string> TargetRegions, bool ExcludeFromLatest);
