using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class HostPoolDetailService
{
    private const string ResourceApiVersion = "2021-04-01";
    private const string DesktopVirtualizationApiVersion = "2024-04-03";
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];

    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;

    public HostPoolDetailService(TokenCredential credential, IHttpClientFactory httpClientFactory)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
    }

    public async Task<IReadOnlyList<ScalingPlanReference>> GetScalingPlansAsync(
        string subscriptionId,
        string hostPoolId,
        CancellationToken cancellationToken = default)
    {
        var scalingPlanIds = new List<string>();
        string? nextUrl = $"https://management.azure.com/subscriptions/{subscriptionId}/resources?api-version={ResourceApiVersion}&$filter=resourceType eq 'Microsoft.DesktopVirtualization/scalingPlans'";

        while (!string.IsNullOrWhiteSpace(nextUrl))
        {
            using var document = await GetArmJsonAsync(nextUrl, cancellationToken);
            if (document.RootElement.TryGetProperty("value", out var values))
            {
                foreach (var item in values.EnumerateArray())
                {
                    if (item.TryGetProperty("id", out var id) && !string.IsNullOrWhiteSpace(id.GetString()))
                        scalingPlanIds.Add(id.GetString()!);
                }
            }

            nextUrl = document.RootElement.TryGetProperty("nextLink", out var nextLink)
                ? nextLink.GetString()
                : null;
        }

        var matches = new List<ScalingPlanReference>();
        foreach (var scalingPlanId in scalingPlanIds)
        {
            using var document = await GetArmJsonAsync(
                $"https://management.azure.com{scalingPlanId}?api-version={DesktopVirtualizationApiVersion}",
                cancellationToken);

            if (!document.RootElement.TryGetProperty("properties", out var properties) ||
                !properties.TryGetProperty("hostPoolReferences", out var references))
                continue;

            JsonElement? matchingReference = null;
            foreach (var reference in references.EnumerateArray())
            {
                if (reference.TryGetProperty("hostPoolArmPath", out var path) &&
                    string.Equals(path.GetString()?.TrimEnd('/'), hostPoolId.TrimEnd('/'), StringComparison.OrdinalIgnoreCase))
                {
                    matchingReference = reference;
                    break;
                }
            }

            if (matchingReference is null)
                continue;

            var name = document.RootElement.TryGetProperty("name", out var nameElement)
                ? nameElement.GetString()
                : null;

            if (string.IsNullOrWhiteSpace(name))
                continue;

            bool? enabled = null;
            var referenceElement = matchingReference.Value;
            if (referenceElement.TryGetProperty("scalingPlanEnabled", out var enabledElement) &&
                enabledElement.ValueKind is JsonValueKind.True or JsonValueKind.False)
            {
                enabled = enabledElement.GetBoolean();
            }

            matches.Add(new ScalingPlanReference(name!, enabled));
        }

        return matches.OrderBy(plan => plan.Name).ToList();
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
}

public sealed record ScalingPlanReference(string Name, bool? Enabled);
