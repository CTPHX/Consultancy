using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class MappingsModel : PageModel
{
    private readonly AzureDiscoveryService _azureDiscovery;
    private readonly ILogger<MappingsModel> _logger;

    public MappingsModel(AzureDiscoveryService azureDiscovery, ILogger<MappingsModel> logger)
    {
        _azureDiscovery = azureDiscovery;
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
            ResourceGroups = Result.Resources
                .Select(r => r.ResourceGroup)
                .Where(rg => !string.IsNullOrWhiteSpace(rg))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(rg => rg)
                .ToList();
            HostPools = BuildMappings(Result.Resources);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Mapping review failed for subscription {SubscriptionId}.", subscriptionId);
            ErrorMessage = "AVD Manager could not build the environment mapping review.";
        }
    }

    private static IReadOnlyList<HostPoolMapping> BuildMappings(IReadOnlyList<AzureDiscoveredResource> resources)
    {
        var hostPools = resources.Where(r => r.Category == "AVD Host Pools").ToList();
        var applicationGroups = resources.Where(r => r.Category == "AVD Application Groups").ToList();
        var vms = resources.Where(r => r.Category == "Virtual Machines").ToList();

        return hostPools.Select(hostPool =>
        {
            var sameRgApps = applicationGroups
                .Where(a => a.ResourceGroup.Equals(hostPool.ResourceGroup, StringComparison.OrdinalIgnoreCase))
                .ToList();

            var sameRgVms = vms
                .Where(v => v.ResourceGroup.Equals(hostPool.ResourceGroup, StringComparison.OrdinalIgnoreCase))
                .ToList();

            var defaults = new ResourceGroupDefaults(
                Avd: hostPool.ResourceGroup,
                SessionHosts: FirstResourceGroup(resources, "Virtual Machines"),
                Network: FirstResourceGroup(resources, "Virtual Networks"),
                Gallery: FirstResourceGroup(resources, "Compute Galleries"),
                Storage: FirstResourceGroup(resources, "Storage Accounts"),
                Automation: FirstResourceGroup(resources, "Automation Accounts"),
                KeyVault: FirstResourceGroup(resources, "Key Vaults"));

            return new HostPoolMapping(hostPool, sameRgApps, sameRgVms, defaults);
        }).OrderBy(m => m.HostPool.Name).ToList();
    }

    private static string? FirstResourceGroup(IReadOnlyList<AzureDiscoveredResource> resources, string category) =>
        resources
            .Where(r => r.Category == category && !string.IsNullOrWhiteSpace(r.ResourceGroup))
            .Select(r => r.ResourceGroup)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(rg => rg)
            .FirstOrDefault();
}

public sealed record HostPoolMapping(
    AzureDiscoveredResource HostPool,
    IReadOnlyList<AzureDiscoveredResource> ApplicationGroups,
    IReadOnlyList<AzureDiscoveredResource> CandidateVirtualMachines,
    ResourceGroupDefaults Defaults);

public sealed record ResourceGroupDefaults(
    string? Avd,
    string? SessionHosts,
    string? Network,
    string? Gallery,
    string? Storage,
    string? Automation,
    string? KeyVault);
