using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AzurePermissionReadinessService
{
    private const string ArmScope = "https://management.azure.com/.default";
    private const string ApiVersion = "2022-04-01";
    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<AzurePermissionReadinessService> _logger;

    private static readonly string[] HostPoolRequiredActions =
    [
        "Microsoft.DesktopVirtualization/hostPools/read",
        "Microsoft.DesktopVirtualization/hostPools/sessionHosts/read",
        "Microsoft.DesktopVirtualization/hostPools/sessionHosts/userSessions/read",
        "Microsoft.DesktopVirtualization/hostPools/sessionHosts/write"
    ];

    private static readonly string[] HostPoolForceLogoffActions =
    [
        "Microsoft.DesktopVirtualization/hostPools/sessionHosts/userSessions/delete"
    ];

    private static readonly string[] AutomationRequiredActions =
    [
        "Microsoft.Automation/automationAccounts/runbooks/read",
        "Microsoft.Automation/automationAccounts/jobs/read",
        "Microsoft.Automation/automationAccounts/jobs/write"
    ];

    public AzurePermissionReadinessService(
        TokenCredential credential,
        IHttpClientFactory httpClientFactory,
        ILogger<AzurePermissionReadinessService> logger)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
        _logger = logger;
    }

    public async Task<DeploymentPermissionReadiness> CheckAsync(
        EnvironmentConfiguration environment,
        SavedHostPoolConfiguration pool,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var hostPoolRg = GetResourceGroupFromArmId(pool.HostPoolId);
            if (string.IsNullOrWhiteSpace(hostPoolRg))
                return DeploymentPermissionReadiness.Unknown("Host pool resource group could not be resolved.");

            var hostPoolScope = $"/subscriptions/{environment.SubscriptionId}/resourceGroups/{hostPoolRg}";
            var hostPoolPermissions = await GetPermissionsAsync(hostPoolScope, cancellationToken);

            var missingCore = HostPoolRequiredActions
                .Where(action => !IsAllowed(hostPoolPermissions, action))
                .ToList();

            var missingForceLogoff = HostPoolForceLogoffActions
                .Where(action => !IsAllowed(hostPoolPermissions, action))
                .ToList();

            var missingAutomation = new List<string>();
            if (environment.Automation is null)
            {
                missingAutomation.Add("Azure Automation configuration");
            }
            else
            {
                var automationScope =
                    $"/subscriptions/{environment.SubscriptionId}/resourceGroups/{environment.Automation.ResourceGroupName}" +
                    $"/providers/Microsoft.Automation/automationAccounts/{environment.Automation.AutomationAccountName}";

                var automationPermissions = await GetPermissionsAsync(automationScope, cancellationToken);
                missingAutomation.AddRange(AutomationRequiredActions
                    .Where(action => !IsAllowed(automationPermissions, action)));
            }

            var allBlocking = missingCore.Concat(missingAutomation).ToList();

            if (allBlocking.Count == 0 && missingForceLogoff.Count == 0)
                return DeploymentPermissionReadiness.Ready();

            if (allBlocking.Count == 0)
            {
                return new DeploymentPermissionReadiness(
                    "Warning",
                    "Core deployment permissions are available, but forced logoff is not permitted for this host pool.",
                    [],
                    missingForceLogoff);
            }

            return new DeploymentPermissionReadiness(
                "Missing",
                "One or more permissions required for deployment are missing.",
                allBlocking,
                missingForceLogoff);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not determine deployment permission readiness for host pool {HostPoolName}.", pool.HostPoolName);
            return DeploymentPermissionReadiness.Unknown(
                "AVD Manager could not verify effective Azure permissions. Deployment should remain blocked until permissions are confirmed.");
        }
    }

    private async Task<IReadOnlyList<AzurePermissionBlock>> GetPermissionsAsync(
        string resourceScope,
        CancellationToken cancellationToken)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext([ArmScope]), cancellationToken);
        var client = _httpClientFactory.CreateClient();
        var url = $"https://management.azure.com{resourceScope}/providers/Microsoft.Authorization/permissions?api-version={ApiVersion}";
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        using var response = await client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Azure returned {(int)response.StatusCode} while checking effective permissions.");

        using var document = JsonDocument.Parse(body);
        var blocks = new List<AzurePermissionBlock>();
        if (!document.RootElement.TryGetProperty("value", out var values) || values.ValueKind != JsonValueKind.Array)
            return blocks;

        foreach (var item in values.EnumerateArray())
        {
            blocks.Add(new AzurePermissionBlock(
                ReadStringArray(item, "actions"),
                ReadStringArray(item, "notActions")));
        }

        return blocks;
    }

    private static IReadOnlyList<string> ReadStringArray(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var property) || property.ValueKind != JsonValueKind.Array)
            return [];
        return property.EnumerateArray()
            .Where(item => item.ValueKind == JsonValueKind.String)
            .Select(item => item.GetString())
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!)
            .ToList();
    }

    private static bool IsAllowed(IReadOnlyList<AzurePermissionBlock> blocks, string requiredAction) =>
        blocks.Any(block =>
            block.Actions.Any(pattern => Matches(pattern, requiredAction)) &&
            !block.NotActions.Any(pattern => Matches(pattern, requiredAction)));

    private static bool Matches(string pattern, string value)
    {
        if (pattern == "*") return true;
        if (!pattern.Contains('*'))
            return pattern.Equals(value, StringComparison.OrdinalIgnoreCase);

        var parts = pattern.Split('*');
        var position = 0;
        for (var index = 0; index < parts.Length; index++)
        {
            var part = parts[index];
            if (part.Length == 0) continue;

            var found = value.IndexOf(part, position, StringComparison.OrdinalIgnoreCase);
            if (found < 0) return false;
            if (index == 0 && !pattern.StartsWith('*') && found != 0) return false;
            position = found + part.Length;
        }

        return pattern.EndsWith('*') ||
               parts[^1].Length == 0 ||
               value.EndsWith(parts[^1], StringComparison.OrdinalIgnoreCase);
    }

    private static string? GetResourceGroupFromArmId(string resourceId)
    {
        var parts = resourceId.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
            if (parts[i].Equals("resourceGroups", StringComparison.OrdinalIgnoreCase))
                return parts[i + 1];
        return null;
    }

    private sealed record AzurePermissionBlock(IReadOnlyList<string> Actions, IReadOnlyList<string> NotActions);
}

public sealed record DeploymentPermissionReadiness(
    string State,
    string Message,
    IReadOnlyList<string> MissingRequiredActions,
    IReadOnlyList<string> MissingOptionalActions)
{
    public bool IsBlocking => State is "Missing" or "Unknown";
    public static DeploymentPermissionReadiness Ready() =>
        new("Ready", "Required AVD Manager deployment permissions are available.", [], []);

    public static DeploymentPermissionReadiness Unknown(string message) =>
        new("Unknown", message, [], []);
}
