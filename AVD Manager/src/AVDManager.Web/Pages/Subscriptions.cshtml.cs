using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class SubscriptionsModel : PageModel
{
    private readonly AzureDiscoveryService _azureDiscovery;
    private readonly ILogger<SubscriptionsModel> _logger;

    public SubscriptionsModel(AzureDiscoveryService azureDiscovery, ILogger<SubscriptionsModel> logger)
    {
        _azureDiscovery = azureDiscovery;
        _logger = logger;
    }

    public IReadOnlyList<AzureSubscription> Subscriptions { get; private set; } = [];
    public string? ErrorMessage { get; private set; }

    public async Task OnGetAsync(CancellationToken cancellationToken)
    {
        try
        {
            Subscriptions = await _azureDiscovery.GetSubscriptionsAsync(cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Application identity Azure subscription discovery failed.");
            ErrorMessage = "AVD Manager could not read Azure subscriptions with its application identity.";
        }
    }
}
