using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AzureDiscoveryService
{
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];
    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;

    public AzureDiscoveryService(TokenCredential credential, IHttpClientFactory httpClientFactory)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
    }

    public async Task<IReadOnlyList<AzureSubscription>> GetSubscriptionsAsync(CancellationToken cancellationToken = default)
    {
        using var document = await GetArmJsonAsync(
            "https://management.azure.com/subscriptions?api-version=2022-12-01",
            cancellationToken);

        var subscriptions = new List<AzureSubscription>();
        if (!document.RootElement.TryGetProperty("value", out var values))
            return subscriptions;

        foreach (var item in values.EnumerateArray())
        {
            subscriptions.Add(new AzureSubscription(
                item.GetProperty("subscriptionId").GetString() ?? string.Empty,
                item.GetProperty("displayName").GetString() ?? "Unnamed subscription",
                item.TryGetProperty("state", out var state) ? state.GetString() ?? "Unknown" : "Unknown"));
        }

        return subscriptions.OrderBy(s => s.DisplayName).ToList();
    }

    public async Task<AzureDiscoveryResult> DiscoverSubscriptionAsync(
        string subscriptionId,
        CancellationToken cancellationToken = default)
    {
        if (!Guid.TryParse(subscriptionId, out _))
            throw new ArgumentException("A valid Azure subscription ID is required.", nameof(subscriptionId));

        var subscriptions = await GetSubscriptionsAsync(cancellationToken);
        var subscription = subscriptions.FirstOrDefault(s =>
            string.Equals(s.SubscriptionId, subscriptionId, StringComparison.OrdinalIgnoreCase));

        if (subscription is null)
            throw new InvalidOperationException("The AVD Manager application identity cannot access that subscription.");

        var resources = new List<AzureDiscoveredResource>();
        string? nextUrl = $"https://management.azure.com/subscriptions/{subscriptionId}/resources?api-version=2021-04-01";

        while (!string.IsNullOrWhiteSpace(nextUrl))
        {
            using var document = await GetArmJsonAsync(nextUrl, cancellationToken);
            if (document.RootElement.TryGetProperty("value", out var values))
            {
                foreach (var item in values.EnumerateArray())
                {
                    var type = item.TryGetProperty("type", out var typeElement)
                        ? typeElement.GetString() ?? string.Empty
                        : string.Empty;

                    var category = Categorise(type);
                    if (category is null)
                        continue;

                    resources.Add(new AzureDiscoveredResource(
                        item.TryGetProperty("id", out var id) ? id.GetString() ?? string.Empty : string.Empty,
                        item.TryGetProperty("name", out var name) ? name.GetString() ?? "Unnamed resource" : "Unnamed resource",
                        type,
                        item.TryGetProperty("location", out var location) ? location.GetString() ?? "Global" : "Global",
                        GetResourceGroup(item),
                        category));
                }
            }

            nextUrl = document.RootElement.TryGetProperty("nextLink", out var nextLink)
                ? nextLink.GetString()
                : null;
        }

        return new AzureDiscoveryResult(
            subscription,
            resources
                .OrderBy(r => r.Category)
                .ThenBy(r => r.Name)
                .ToList());
    }

    private async Task<JsonDocument> GetArmJsonAsync(string url, CancellationToken cancellationToken)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext(ArmScopes), cancellationToken);
        var client = _httpClientFactory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

        using var response = await client.GetAsync(url, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Azure Resource Manager returned {(int)response.StatusCode}: {body}");

        return JsonDocument.Parse(body);
    }

    private static string GetResourceGroup(JsonElement item)
    {
        if (!item.TryGetProperty("id", out var idElement))
            return string.Empty;

        var id = idElement.GetString();
        if (string.IsNullOrWhiteSpace(id))
            return string.Empty;

        var parts = id.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
        {
            if (parts[i].Equals("resourceGroups", StringComparison.OrdinalIgnoreCase))
                return parts[i + 1];
        }

        return string.Empty;
    }

    private static string? Categorise(string resourceType)
    {
        var type = resourceType.ToLowerInvariant();

        if (type.StartsWith("microsoft.desktopvirtualization/hostpools")) return "AVD Host Pools";
        if (type.StartsWith("microsoft.desktopvirtualization/workspaces")) return "AVD Workspaces";
        if (type.StartsWith("microsoft.desktopvirtualization/applicationgroups")) return "AVD Application Groups";
        if (type.StartsWith("microsoft.desktopvirtualization/scalingplans")) return "AVD Scaling Plans";
        if (type == "microsoft.compute/virtualmachines") return "Virtual Machines";
        if (type == "microsoft.compute/galleries") return "Compute Galleries";
        if (type.StartsWith("microsoft.compute/galleries/images/versions")) return "Gallery Image Versions";
        if (type.StartsWith("microsoft.compute/galleries/images")) return "Gallery Images";
        if (type == "microsoft.storage/storageaccounts") return "Storage Accounts";
        if (type == "microsoft.automation/automationaccounts") return "Automation Accounts";
        if (type == "microsoft.keyvault/vaults") return "Key Vaults";
        if (type == "microsoft.network/virtualnetworks") return "Virtual Networks";
        if (type == "microsoft.network/networkinterfaces") return "Network Interfaces";

        return null;
    }
}

public sealed record AzureSubscription(string SubscriptionId, string DisplayName, string State);

public sealed record AzureDiscoveredResource(
    string Id,
    string Name,
    string Type,
    string Location,
    string ResourceGroup,
    string Category);

public sealed record AzureDiscoveryResult(
    AzureSubscription Subscription,
    IReadOnlyList<AzureDiscoveredResource> Resources);
