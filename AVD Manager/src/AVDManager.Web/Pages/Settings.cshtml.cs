using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class SettingsModel : PageModel
{
    private const string DeploymentRunbookName = "DeployAVDHosts";
    private readonly AzureDiscoveryService _azureDiscovery;
    private readonly AzureAutomationService _automation;
    private readonly EnvironmentConfigurationStore _configurationStore;
    private readonly ILogger<SettingsModel> _logger;

    public SettingsModel(AzureDiscoveryService azureDiscovery, AzureAutomationService automation, EnvironmentConfigurationStore configurationStore, ILogger<SettingsModel> logger)
    {
        _azureDiscovery = azureDiscovery;
        _automation = automation;
        _configurationStore = configurationStore;
        _logger = logger;
    }

    [BindProperty(SupportsGet = true)] public string? SubscriptionId { get; set; }
    [BindProperty] public string? AutomationAccountId { get; set; }
    public AzureSubscription? Subscription { get; private set; }
    public EnvironmentConfiguration? EnvironmentConfiguration { get; private set; }
    public IReadOnlyList<AutomationAccountOption> AutomationAccounts { get; private set; } = [];
    public string? ErrorMessage { get; private set; }
    public string DeploymentRunbook => DeploymentRunbookName;

    public async Task OnGetAsync(CancellationToken cancellationToken) => await LoadAsync(cancellationToken);

    public async Task<IActionResult> OnPostSaveAutomationAsync(CancellationToken cancellationToken)
    {
        var configuration = await _configurationStore.GetAsync(cancellationToken);
        if (configuration is null) return RedirectToPage("/Onboarding");
        SubscriptionId = configuration.SubscriptionId;

        try
        {
            AutomationAccounts = await _automation.GetAccountsAsync(configuration.SubscriptionId, cancellationToken);
            var account = AutomationAccounts.FirstOrDefault(a => string.Equals(a.Id, AutomationAccountId, StringComparison.OrdinalIgnoreCase));
            if (account is null)
            {
                ErrorMessage = "Select an Automation Account discovered in the configured subscription.";
                await LoadSubscriptionAsync(configuration, cancellationToken);
                EnvironmentConfiguration = configuration;
                return Page();
            }

            var runbook = await _automation.ValidatePublishedRunbookAsync(configuration.SubscriptionId, account.ResourceGroup, account.Name, DeploymentRunbookName, cancellationToken);
            if (!runbook.IsPublished)
            {
                ErrorMessage = $"Runbook '{DeploymentRunbookName}' exists but is not published. Publish it in Azure Automation before saving this deployment configuration.";
                await LoadSubscriptionAsync(configuration, cancellationToken);
                EnvironmentConfiguration = configuration;
                return Page();
            }

            var updated = configuration with
            {
                SavedAtUtc = DateTimeOffset.UtcNow,
                Automation = new SavedAutomationConfiguration(account.Id, account.Name, account.ResourceGroup, DeploymentRunbookName, DateTimeOffset.UtcNow)
            };
            await _configurationStore.SaveAsync(updated, cancellationToken);
            TempData["StatusMessage"] = $"Automation deployment configured: {account.Name} / {DeploymentRunbookName}";
            return RedirectToPage("/Settings");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Could not validate Automation deployment configuration.");
            ErrorMessage = $"AVD Manager could not validate published runbook '{DeploymentRunbookName}' in the selected Automation Account.";
            EnvironmentConfiguration = configuration;
            await LoadSubscriptionAsync(configuration, cancellationToken);
            return Page();
        }
    }

    public async Task<IActionResult> OnPostRescanAsync(CancellationToken cancellationToken)
    {
        var configuration = await _configurationStore.GetAsync(cancellationToken);
        SubscriptionId = configuration?.SubscriptionId ?? SubscriptionId;
        if (string.IsNullOrWhiteSpace(SubscriptionId) || !Guid.TryParse(SubscriptionId, out _)) return RedirectToPage("/Subscriptions");
        return RedirectToPage("/Discovery", new { subscriptionId = SubscriptionId });
    }

    private async Task LoadAsync(CancellationToken cancellationToken)
    {
        EnvironmentConfiguration = await _configurationStore.GetAsync(cancellationToken);
        SubscriptionId ??= EnvironmentConfiguration?.SubscriptionId;
        if (EnvironmentConfiguration is null || string.IsNullOrWhiteSpace(SubscriptionId)) return;
        AutomationAccountId ??= EnvironmentConfiguration.Automation?.AutomationAccountId;
        try
        {
            await LoadSubscriptionAsync(EnvironmentConfiguration, cancellationToken);
            AutomationAccounts = await _automation.GetAccountsAsync(EnvironmentConfiguration.SubscriptionId, cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Could not load Azure environment settings for {SubscriptionId}.", SubscriptionId);
            ErrorMessage = "AVD Manager could not read the configured Azure environment with its application identity.";
        }
    }

    private async Task LoadSubscriptionAsync(EnvironmentConfiguration configuration, CancellationToken cancellationToken)
    {
        var subscriptions = await _azureDiscovery.GetSubscriptionsAsync(cancellationToken);
        Subscription = subscriptions.FirstOrDefault(s => s.SubscriptionId.Equals(configuration.SubscriptionId, StringComparison.OrdinalIgnoreCase));
    }
}
