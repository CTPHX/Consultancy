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
    public string? ErrorMessage { get; private set; }

    public async Task OnGetAsync(string subscriptionId, CancellationToken cancellationToken)
    {
        try
        {
            Result = await _azureDiscovery.DiscoverSubscriptionAsync(subscriptionId, cancellationToken);
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

            return new HostPoolMapping(hostPool, sameRgApps, sameRgVms);
        }).OrderBy(m => m.HostPool.Name).ToList();
    }
}

public sealed record HostPoolMapping(
    AzureDiscoveredResource HostPool,
    IReadOnlyList<AzureDiscoveredResource> ApplicationGroups,
    IReadOnlyList<AzureDiscoveredResource> CandidateVirtualMachines);
