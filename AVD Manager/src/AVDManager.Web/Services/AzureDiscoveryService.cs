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
        var token = await _credential.GetTokenAsync(new TokenRequestContext(ArmScopes), cancellationToken);
        var client = _httpClientFactory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

        using var response = await client.GetAsync(
            "https://management.azure.com/subscriptions?api-version=2022-12-01",
            cancellationToken);

        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Azure Resource Manager returned {(int)response.StatusCode}: {body}");

        using var document = JsonDocument.Parse(body);
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
}

public sealed record AzureSubscription(string SubscriptionId, string DisplayName, string State);
