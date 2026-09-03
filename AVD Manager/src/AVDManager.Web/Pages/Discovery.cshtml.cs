using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class DiscoveryModel : PageModel
{
    private readonly AzureDiscoveryService _azureDiscovery;
    private readonly ILogger<DiscoveryModel> _logger;

    public DiscoveryModel(AzureDiscoveryService azureDiscovery, ILogger<DiscoveryModel> logger)
    {
        _azureDiscovery = azureDiscovery;
        _logger = logger;
    }

    public AzureDiscoveryResult? Result { get; private set; }
    public string? ErrorMessage { get; private set; }

    public async Task OnGetAsync(string subscriptionId, CancellationToken cancellationToken)
    {
        try
        {
            Result = await _azureDiscovery.DiscoverSubscriptionAsync(subscriptionId, cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Azure resource discovery failed for subscription {SubscriptionId}.", subscriptionId);
            ErrorMessage = "AVD Manager could not complete the read-only resource scan for this subscription.";
        }
    }
}
