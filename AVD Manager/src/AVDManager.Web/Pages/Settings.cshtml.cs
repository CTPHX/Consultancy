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
    [BindProperty] public DeploymentEnvironmentDefaultsInput DeploymentDefaults { get; set; } = new();
    [BindProperty] public List<HostPoolDeploymentDefaultsInput> HostPoolDeploymentDefaults { get; set; } = [];

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
                PopulateDeploymentInputs(configuration);
                return Page();
            }

            var runbook = await _automation.ValidatePublishedRunbookAsync(configuration.SubscriptionId, account.ResourceGroup, account.Name, DeploymentRunbookName, cancellationToken);
            if (!runbook.IsPublished)
            {
                ErrorMessage = $"Runbook '{DeploymentRunbookName}' exists but is not published. Publish it in Azure Automation before saving this deployment configuration.";
                await LoadSubscriptionAsync(configuration, cancellationToken);
                EnvironmentConfiguration = configuration;
                PopulateDeploymentInputs(configuration);
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
            PopulateDeploymentInputs(configuration);
            await LoadSubscriptionAsync(configuration, cancellationToken);
            return Page();
        }
    }

    public async Task<IActionResult> OnPostSaveDeploymentDefaultsAsync(CancellationToken cancellationToken)
    {
        var configuration = await _configurationStore.GetAsync(cancellationToken);
        if (configuration is null) return RedirectToPage("/Onboarding");

        var invalid = HostPoolDeploymentDefaults.FirstOrDefault(x =>
            string.IsNullOrWhiteSpace(x.HostPoolId) ||
            !configuration.HostPools.Any(p => p.HostPoolId.Equals(x.HostPoolId, StringComparison.OrdinalIgnoreCase)) ||
            !(x.JoinType.Equals("ADDS", StringComparison.OrdinalIgnoreCase) || x.JoinType.Equals("ENTRA", StringComparison.OrdinalIgnoreCase)) ||
            string.IsNullOrWhiteSpace(x.DefaultVmSize) ||
            string.IsNullOrWhiteSpace(x.DefaultGalleryImageVersion));

        if (invalid is not null)
        {
            ErrorMessage = "One or more advanced deployment defaults are invalid. Join type must be ADDS or ENTRA, and VM size/image version are required.";
            EnvironmentConfiguration = configuration;
            await LoadSubscriptionAndAutomationAsync(configuration, cancellationToken);
            return Page();
        }

        var updatedPools = configuration.HostPools.Select(pool =>
        {
            var input = HostPoolDeploymentDefaults.FirstOrDefault(x => x.HostPoolId.Equals(pool.HostPoolId, StringComparison.OrdinalIgnoreCase));
            if (input is null) return pool;

            return pool with
            {
                DeploymentDefaults = new SavedHostPoolDeploymentDefaults(
                    input.JoinType.ToUpperInvariant(),
                    input.DefaultVmSize.Trim(),
                    input.DefaultGalleryImageVersion.Trim(),
                    NullIfWhiteSpace(input.SessionHostResourceGroupName),
                    NullIfWhiteSpace(input.GalleryResourceGroupName),
                    NullIfWhiteSpace(input.GalleryName),
                    NullIfWhiteSpace(input.GalleryImageDefinitionName),
                    NullIfWhiteSpace(input.VirtualNetworkResourceGroupName),
                    NullIfWhiteSpace(input.VirtualNetworkName),
                    NullIfWhiteSpace(input.SubnetName),
                    NullIfWhiteSpace(input.KeyVaultName),
                    NullIfWhiteSpace(input.DomainFqdn),
                    NullIfWhiteSpace(input.DomainOuPath),
                    input.InstallRdsRoleOnServerOs,
                    input.TemporarilyDisableScalingDuringDeployment)
            };
        }).ToList();

        var environmentDefaults = new SavedDeploymentEnvironmentDefaults(
            string.IsNullOrWhiteSpace(DeploymentDefaults.LocalAdminUsernameSecretName) ? "adm-local-upn" : DeploymentDefaults.LocalAdminUsernameSecretName.Trim(),
            string.IsNullOrWhiteSpace(DeploymentDefaults.LocalAdminPasswordSecretName) ? "adm-local-pw" : DeploymentDefaults.LocalAdminPasswordSecretName.Trim(),
            string.IsNullOrWhiteSpace(DeploymentDefaults.DomainJoinUsernameSecretName) ? "domainjoin-upn" : DeploymentDefaults.DomainJoinUsernameSecretName.Trim(),
            string.IsNullOrWhiteSpace(DeploymentDefaults.DomainJoinPasswordSecretName) ? "domainjoin-pw" : DeploymentDefaults.DomainJoinPasswordSecretName.Trim(),
            NullIfWhiteSpace(DeploymentDefaults.TenantId),
            DeploymentDefaults.EnableIntuneEnrollment,
            NullIfWhiteSpace(DeploymentDefaults.IntuneMdmId),
            string.IsNullOrWhiteSpace(DeploymentDefaults.EnvironmentTagValue) ? "Prod" : DeploymentDefaults.EnvironmentTagValue.Trim());

        await _configurationStore.SaveAsync(configuration with
        {
            SavedAtUtc = DateTimeOffset.UtcNow,
            HostPools = updatedPools,
            DeploymentDefaults = environmentDefaults
        }, cancellationToken);

        TempData["StatusMessage"] = "Advanced deployment defaults saved.";
        return RedirectToPage("/Settings");
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
        PopulateDeploymentInputs(EnvironmentConfiguration);
        try
        {
            await LoadSubscriptionAndAutomationAsync(EnvironmentConfiguration, cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Could not load Azure environment settings for {SubscriptionId}.", SubscriptionId);
            ErrorMessage = "AVD Manager could not read the configured Azure environment with its application identity.";
        }
    }

    private async Task LoadSubscriptionAndAutomationAsync(EnvironmentConfiguration configuration, CancellationToken cancellationToken)
    {
        await LoadSubscriptionAsync(configuration, cancellationToken);
        AutomationAccounts = await _automation.GetAccountsAsync(configuration.SubscriptionId, cancellationToken);
    }

    private void PopulateDeploymentInputs(EnvironmentConfiguration configuration)
    {
        var environmentDefaults = configuration.DeploymentDefaults;
        DeploymentDefaults = new DeploymentEnvironmentDefaultsInput
        {
            LocalAdminUsernameSecretName = environmentDefaults?.LocalAdminUsernameSecretName ?? "adm-local-upn",
            LocalAdminPasswordSecretName = environmentDefaults?.LocalAdminPasswordSecretName ?? "adm-local-pw",
            DomainJoinUsernameSecretName = environmentDefaults?.DomainJoinUsernameSecretName ?? "domainjoin-upn",
            DomainJoinPasswordSecretName = environmentDefaults?.DomainJoinPasswordSecretName ?? "domainjoin-pw",
            TenantId = environmentDefaults?.TenantId,
            EnableIntuneEnrollment = environmentDefaults?.EnableIntuneEnrollment ?? true,
            IntuneMdmId = environmentDefaults?.IntuneMdmId ?? "0000000a-0000-0000-c000-000000000000",
            EnvironmentTagValue = environmentDefaults?.EnvironmentTagValue ?? "Prod"
        };

        HostPoolDeploymentDefaults = configuration.HostPools.OrderBy(p => p.HostPoolName, StringComparer.OrdinalIgnoreCase).Select(pool =>
        {
            var d = pool.DeploymentDefaults;
            var host = pool.SessionHosts.FirstOrDefault();
            return new HostPoolDeploymentDefaultsInput
            {
                HostPoolId = pool.HostPoolId,
                HostPoolName = pool.HostPoolName,
                JoinType = d?.JoinType ?? "ADDS",
                DefaultVmSize = d?.DefaultVmSize ?? "Standard_D2ds_v6",
                DefaultGalleryImageVersion = d?.DefaultGalleryImageVersion ?? "Latest",
                SessionHostResourceGroupName = d?.SessionHostResourceGroupName ?? pool.ResourceGroups.SessionHosts,
                GalleryResourceGroupName = d?.GalleryResourceGroupName ?? pool.ResourceGroups.Gallery,
                GalleryName = d?.GalleryName ?? host?.GalleryName,
                GalleryImageDefinitionName = d?.GalleryImageDefinitionName ?? host?.ImageDefinition,
                VirtualNetworkResourceGroupName = d?.VirtualNetworkResourceGroupName ?? pool.ResourceGroups.Network,
                VirtualNetworkName = d?.VirtualNetworkName ?? host?.VnetName,
                SubnetName = d?.SubnetName ?? host?.SubnetName,
                KeyVaultName = d?.KeyVaultName,
                DomainFqdn = d?.DomainFqdn,
                DomainOuPath = d?.DomainOuPath,
                InstallRdsRoleOnServerOs = d?.InstallRdsRoleOnServerOs ?? false,
                TemporarilyDisableScalingDuringDeployment = d?.TemporarilyDisableScalingDuringDeployment ?? true
            };
        }).ToList();
    }

    private async Task LoadSubscriptionAsync(EnvironmentConfiguration configuration, CancellationToken cancellationToken)
    {
        var subscriptions = await _azureDiscovery.GetSubscriptionsAsync(cancellationToken);
        Subscription = subscriptions.FirstOrDefault(s => s.SubscriptionId.Equals(configuration.SubscriptionId, StringComparison.OrdinalIgnoreCase));
    }

    private static string? NullIfWhiteSpace(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}

public sealed class DeploymentEnvironmentDefaultsInput
{
    public string LocalAdminUsernameSecretName { get; set; } = "adm-local-upn";
    public string LocalAdminPasswordSecretName { get; set; } = "adm-local-pw";
    public string DomainJoinUsernameSecretName { get; set; } = "domainjoin-upn";
    public string DomainJoinPasswordSecretName { get; set; } = "domainjoin-pw";
    public string? TenantId { get; set; }
    public bool EnableIntuneEnrollment { get; set; } = true;
    public string? IntuneMdmId { get; set; } = "0000000a-0000-0000-c000-000000000000";
    public string EnvironmentTagValue { get; set; } = "Prod";
}

public sealed class HostPoolDeploymentDefaultsInput
{
    public string HostPoolId { get; set; } = string.Empty;
    public string HostPoolName { get; set; } = string.Empty;
    public string JoinType { get; set; } = "ADDS";
    public string DefaultVmSize { get; set; } = "Standard_D2ds_v6";
    public string DefaultGalleryImageVersion { get; set; } = "Latest";
    public string? SessionHostResourceGroupName { get; set; }
    public string? GalleryResourceGroupName { get; set; }
    public string? GalleryName { get; set; }
    public string? GalleryImageDefinitionName { get; set; }
    public string? VirtualNetworkResourceGroupName { get; set; }
    public string? VirtualNetworkName { get; set; }
    public string? SubnetName { get; set; }
    public string? KeyVaultName { get; set; }
    public string? DomainFqdn { get; set; }
    public string? DomainOuPath { get; set; }
    public bool InstallRdsRoleOnServerOs { get; set; }
    public bool TemporarilyDisableScalingDuringDeployment { get; set; } = true;
}
