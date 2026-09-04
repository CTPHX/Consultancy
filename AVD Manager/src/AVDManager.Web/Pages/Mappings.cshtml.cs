using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class MappingsModel : PageModel
{
    private readonly AzureDiscoveryService _azureDiscovery;
    private readonly AzureVmImageDiscoveryService _imageDiscovery;
    private readonly ILogger<MappingsModel> _logger;

    public MappingsModel(
        AzureDiscoveryService azureDiscovery,
        AzureVmImageDiscoveryService imageDiscovery,
        ILogger<MappingsModel> logger)
    {
        _azureDiscovery = azureDiscovery;
        _imageDiscovery = imageDiscovery;
        _logger = logger;
    }

    public AzureDiscoveryResult? Result { get; private set; }
    public IReadOnlyList<HostPoolMapping> HostPools { get; private set; } = [];
    public IReadOnlyList<string> ResourceGroups { get; private set; } = [];
    public string? ErrorMessage { get; private set; }

    public async Task OnGetAsync(string subscriptionId, CancellationToken cancellationToken)
    {
        try
        {
            Result = await _azureDiscovery.DiscoverSubscriptionAsync(subscriptionId, cancellationToken);
            var imageReferences = new Dictionary<string, AzureVmImageReference>(StringComparer.OrdinalIgnoreCase);

            foreach (var vm in Result.SessionHosts
                         .Select(h => h.VirtualMachine)
                         .Where(vm => vm is not null)
                         .Select(vm => vm!)
                         .DistinctBy(vm => vm.Id, StringComparer.OrdinalIgnoreCase))
            {
                var image = await _imageDiscovery.DiscoverAsync(vm, cancellationToken);
                if (image is not null)
                    imageReferences[vm.Id] = image;
            }

            ResourceGroups = Result.Resources
                .Select(r => r.ResourceGroup)
                .Concat(Result.SessionHosts.SelectMany(h => h.Networking).Select(n => n.VirtualNetwork?.ResourceGroup))
                .Concat(imageReferences.Values.Select(i => i.GalleryResourceGroup))
                .Where(rg => !string.IsNullOrWhiteSpace(rg))
                .Select(rg => rg!)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(rg => rg)
                .ToList();
            HostPools = BuildMappings(Result, imageReferences);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Mapping review failed for subscription {SubscriptionId}.", subscriptionId);
            ErrorMessage = "AVD Manager could not build the environment mapping review.";
        }
    }

    private static IReadOnlyList<HostPoolMapping> BuildMappings(
        AzureDiscoveryResult result,
        IReadOnlyDictionary<string, AzureVmImageReference> imageReferences)
    {
        var resources = result.Resources;
        var hostPools = resources.Where(r => r.Category == "AVD Host Pools").ToList();
        var applicationGroups = resources.Where(r => r.Category == "AVD Application Groups").ToList();

        return hostPools.Select(hostPool =>
        {
            var linkedApps = applicationGroups
                .Where(a => !string.IsNullOrWhiteSpace(a.HostPoolArmPath) &&
                            ArmIdEquals(a.HostPoolArmPath, hostPool.Id))
                .OrderBy(a => a.ApplicationGroupType)
                .ThenBy(a => a.Name)
                .ToList();

            var sessionHosts = result.SessionHosts
                .Where(h => ArmIdEquals(h.HostPoolArmPath, hostPool.Id))
                .OrderBy(h => h.Name)
                .ToList();

            var sessionHostImages = sessionHosts
                .Where(h => h.VirtualMachine is not null && imageReferences.ContainsKey(h.VirtualMachine.Id))
                .Select(h => new SessionHostImageMapping(h, imageReferences[h.VirtualMachine!.Id]))
                .ToList();

            var authoritativeVmResourceGroup = sessionHosts
                .Select(h => h.VirtualMachine?.ResourceGroup)
                .FirstOrDefault(rg => !string.IsNullOrWhiteSpace(rg));

            var authoritativeNetworkResourceGroup = sessionHosts
                .SelectMany(h => h.Networking)
                .Select(n => n.VirtualNetwork?.ResourceGroup)
                .FirstOrDefault(rg => !string.IsNullOrWhiteSpace(rg));

            var authoritativeGalleryResourceGroup = sessionHostImages
                .Select(i => i.Image.GalleryResourceGroup)
                .FirstOrDefault(rg => !string.IsNullOrWhiteSpace(rg));

            var defaults = new ResourceGroupDefaults(
                Avd: hostPool.ResourceGroup,
                SessionHosts: authoritativeVmResourceGroup ?? FirstResourceGroup(resources, "Virtual Machines"),
                Network: authoritativeNetworkResourceGroup ?? FirstResourceGroup(resources, "Virtual Networks"),
                Gallery: authoritativeGalleryResourceGroup ?? FirstResourceGroup(resources, "Compute Galleries"),
                Storage: FirstResourceGroup(resources, "Storage Accounts"),
                Automation: FirstResourceGroup(resources, "Automation Accounts"),
                KeyVault: FirstResourceGroup(resources, "Key Vaults"));

            return new HostPoolMapping(hostPool, linkedApps, sessionHosts, sessionHostImages, defaults);
        }).OrderBy(m => m.HostPool.Name).ToList();
    }

    private static bool ArmIdEquals(string? left, string? right) =>
        string.Equals(left?.TrimEnd('/'), right?.TrimEnd('/'), StringComparison.OrdinalIgnoreCase);

    private static string? FirstResourceGroup(IReadOnlyList<AzureDiscoveredResource> resources, string category) =>
        resources
            .Where(r => r.Category == category && !string.IsNullOrWhiteSpace(r.ResourceGroup))
            .Select(r => r.ResourceGroup)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(rg => rg)
            .FirstOrDefault();
}

public sealed record SessionHostImageMapping(
    AzureSessionHost SessionHost,
    AzureVmImageReference Image);

public sealed record HostPoolMapping(
    AzureDiscoveredResource HostPool,
    IReadOnlyList<AzureDiscoveredResource> ApplicationGroups,
    IReadOnlyList<AzureSessionHost> SessionHosts,
    IReadOnlyList<SessionHostImageMapping> SessionHostImages,
    ResourceGroupDefaults Defaults);

public sealed record ResourceGroupDefaults(
    string? Avd,
    string? SessionHosts,
    string? Network,
    string? Gallery,
    string? Storage,
    string? Automation,
    string? KeyVault);
