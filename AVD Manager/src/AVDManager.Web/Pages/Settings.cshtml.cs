using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class SettingsModel : PageModel
{
    private readonly AzureDiscoveryService _azureDiscovery;
    private readonly ILogger<SettingsModel> _logger;

    public SettingsModel(AzureDiscoveryService azureDiscovery, ILogger<SettingsModel> logger)
    {
        _azureDiscovery = azureDiscovery;
        _logger = logger;
    }

    [BindProperty(SupportsGet = true)]
    public string? SubscriptionId { get; set; }

    public AzureSubscription? Subscription { get; private set; }
    public string? ErrorMessage { get; private set; }

    public async Task OnGetAsync(CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(SubscriptionId))
            return;

        try
        {
            var subscriptions = await _azureDiscovery.GetSubscriptionsAsync(cancellationToken);
            Subscription = subscriptions.FirstOrDefault(s =>
                s.SubscriptionId.Equals(SubscriptionId, StringComparison.OrdinalIgnoreCase));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Could not read configured Azure subscription {SubscriptionId} from Settings.", SubscriptionId);
            ErrorMessage = "AVD Manager could not read the Azure subscription with its application identity.";
        }
    }

    public IActionResult OnPostRescan()
    {
        if (string.IsNullOrWhiteSpace(SubscriptionId) || !Guid.TryParse(SubscriptionId, out _))
            return RedirectToPage("/Subscriptions");

        return RedirectToPage("/Discovery", new { subscriptionId = SubscriptionId });
    }
}
