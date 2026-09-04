using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class MappingsModel : PageModel
{
    private readonly AzureDiscoveryService _azureDiscovery;
    private readonly AzureVmImageDiscoveryService _imageDiscovery;
    private readonly EnvironmentConfigurationStore _configurationStore;
    private readonly ILogger<MappingsModel> _logger;

    public MappingsModel(AzureDiscoveryService azureDiscovery, AzureVmImageDiscoveryService imageDiscovery,
        EnvironmentConfigurationStore configurationStore, ILogger<MappingsModel> logger)
    {
        _azureDiscovery = azureDiscovery;
        _imageDiscovery = imageDiscovery;
        _configurationStore = configurationStore;
        _logger = logger;
    }

    [BindProperty(SupportsGet = true)] public string SubscriptionId { get; set; } = string.Empty;
    [BindProperty] public List<HostPoolMappingInput> MappingInputs { get; set; } = [];
    public AzureDiscoveryResult? Result { get; private set; }
    public IReadOnlyList<HostPoolMapping> HostPools { get; private set; } = [];
    public IReadOnlyList<string> ResourceGroups { get; private set; } = [];
    public string? ErrorMessage { get; private set; }

    public async Task OnGetAsync(CancellationToken cancellationToken) => await LoadAsync(SubscriptionId, cancellationToken);

    public async Task<IActionResult> OnPostSaveAsync(CancellationToken cancellationToken)
    {
        if (!Guid.TryParse(SubscriptionId, out _)) return RedirectToPage("/Subscriptions");
        await LoadAsync(SubscriptionId, cancellationToken);
        if (Result is null) return Page();

        var now = DateTimeOffset.UtcNow;
        var savedHostPools = HostPools.Select(mapping =>
        {
            var input = MappingInputs.FirstOrDefault(i => i.HostPoolId.Equals(mapping.HostPool.Id, StringComparison.OrdinalIgnoreCase));
            var rg = input is null ? mapping.Defaults : new ResourceGroupDefaults(input.Avd, input.SessionHosts, input.Network, input.Gallery, input.Storage, input.Automation, input.KeyVault);
            var sessions = mapping.SessionHosts.Select(host =>
            {
                var network = host.Networking.FirstOrDefault(n => n.VirtualNetwork is not null) ?? host.Networking.FirstOrDefault();
                var image = mapping.SessionHostImages.FirstOrDefault(i => i.SessionHost.Id.Equals(host.Id, StringComparison.OrdinalIgnoreCase))?.Image;
                return new SavedSessionHost(host.Name, host.Status, host.AllowNewSession, host.Sessions,
                    host.VirtualMachine?.Name, host.VirtualMachine?.ResourceGroup, network?.NicName,
                    network?.VirtualNetwork?.Name, network?.SubnetName, image?.GalleryName,
                    image?.GalleryResourceGroup, image?.ImageDefinitionName, image?.ImageVersionName ?? image?.ExactVersion ?? image?.Version);
            }).ToList();
            return new SavedHostPoolConfiguration(mapping.HostPool.Id, mapping.HostPool.Name, mapping.HostPool.Location,
                new SavedResourceGroupDefaults(rg.Avd, rg.SessionHosts, rg.Network, rg.Gallery, rg.Storage, rg.Automation, rg.KeyVault),
                mapping.ApplicationGroups.Select(a => a.Name).ToList(), sessions);
        }).ToList();

        await _configurationStore.SaveAsync(new EnvironmentConfiguration(Result.Subscription.SubscriptionId,
            Result.Subscription.DisplayName, now, now, savedHostPools), cancellationToken);
        return RedirectToPage("/Index");
    }

    private async Task LoadAsync(string subscriptionId, CancellationToken cancellationToken)
    {
        try
        {
            Result = await _azureDiscovery.DiscoverSubscriptionAsync(subscriptionId, cancellationToken);
            var images = new Dictionary<string, AzureVmImageReference>(StringComparer.OrdinalIgnoreCase);
            foreach (var vm in Result.SessionHosts.Select(h => h.VirtualMachine).Where(v => v is not null).Select(v => v!).DistinctBy(v => v.Id, StringComparer.OrdinalIgnoreCase))
            {
                var image = await _imageDiscovery.DiscoverAsync(vm, cancellationToken);
                if (image is not null) images[vm.Id] = image;
            }
            ResourceGroups = Result.Resources.Select(r => r.ResourceGroup)
                .Concat(Result.SessionHosts.SelectMany(h => h.Networking).Select(n => n.VirtualNetwork?.ResourceGroup))
                .Concat(images.Values.Select(i => i.GalleryResourceGroup)).Where(r => !string.IsNullOrWhiteSpace(r)).Select(r => r!)
                .Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(r => r).ToList();
            HostPools = BuildMappings(Result, images);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Mapping review failed for subscription {SubscriptionId}.", subscriptionId);
            ErrorMessage = "AVD Manager could not build the environment mapping review.";
        }
    }

    private static IReadOnlyList<HostPoolMapping> BuildMappings(AzureDiscoveryResult result, IReadOnlyDictionary<string, AzureVmImageReference> images)
    {
        var resources = result.Resources;
        var apps = resources.Where(r => r.Category == "AVD Application Groups").ToList();
        return resources.Where(r => r.Category == "AVD Host Pools").Select(hostPool =>
        {
            var linkedApps = apps.Where(a => !string.IsNullOrWhiteSpace(a.HostPoolArmPath) && ArmIdEquals(a.HostPoolArmPath, hostPool.Id)).OrderBy(a => a.Name).ToList();
            var hosts = result.SessionHosts.Where(h => ArmIdEquals(h.HostPoolArmPath, hostPool.Id)).OrderBy(h => h.Name).ToList();
            var hostImages = hosts.Where(h => h.VirtualMachine is not null && images.ContainsKey(h.VirtualMachine.Id)).Select(h => new SessionHostImageMapping(h, images[h.VirtualMachine!.Id])).ToList();
            var defaults = new ResourceGroupDefaults(hostPool.ResourceGroup,
                hosts.Select(h => h.VirtualMachine?.ResourceGroup).FirstOrDefault(r => !string.IsNullOrWhiteSpace(r)) ?? FirstResourceGroup(resources, "Virtual Machines"),
                hosts.SelectMany(h => h.Networking).Select(n => n.VirtualNetwork?.ResourceGroup).FirstOrDefault(r => !string.IsNullOrWhiteSpace(r)) ?? FirstResourceGroup(resources, "Virtual Networks"),
                hostImages.Select(i => i.Image.GalleryResourceGroup).FirstOrDefault(r => !string.IsNullOrWhiteSpace(r)) ?? FirstResourceGroup(resources, "Compute Galleries"),
                FirstResourceGroup(resources, "Storage Accounts"), FirstResourceGroup(resources, "Automation Accounts"), FirstResourceGroup(resources, "Key Vaults"));
            return new HostPoolMapping(hostPool, linkedApps, hosts, hostImages, defaults);
        }).OrderBy(m => m.HostPool.Name).ToList();
    }

    private static bool ArmIdEquals(string? a, string? b) => string.Equals(a?.TrimEnd('/'), b?.TrimEnd('/'), StringComparison.OrdinalIgnoreCase);
    private static string? FirstResourceGroup(IReadOnlyList<AzureDiscoveredResource> resources, string category) => resources.Where(r => r.Category == category && !string.IsNullOrWhiteSpace(r.ResourceGroup)).Select(r => r.ResourceGroup).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(r => r).FirstOrDefault();
}

public sealed class HostPoolMappingInput
{
    public string HostPoolId { get; set; } = string.Empty;
    public string? Avd { get; set; }
    public string? SessionHosts { get; set; }
    public string? Network { get; set; }
    public string? Gallery { get; set; }
    public string? Storage { get; set; }
    public string? Automation { get; set; }
    public string? KeyVault { get; set; }
}
public sealed record SessionHostImageMapping(AzureSessionHost SessionHost, AzureVmImageReference Image);
public sealed record HostPoolMapping(AzureDiscoveredResource HostPool, IReadOnlyList<AzureDiscoveredResource> ApplicationGroups, IReadOnlyList<AzureSessionHost> SessionHosts, IReadOnlyList<SessionHostImageMapping> SessionHostImages, ResourceGroupDefaults Defaults);
public sealed record ResourceGroupDefaults(string? Avd, string? SessionHosts, string? Network, string? Gallery, string? Storage, string? Automation, string? KeyVault);
