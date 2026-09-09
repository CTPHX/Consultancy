using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AzureAutomationService
{
    private const string ApiVersion = "2024-10-23";
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];
    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;

    public AzureAutomationService(TokenCredential credential, IHttpClientFactory httpClientFactory)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
    }

    public async Task<IReadOnlyList<AutomationAccountOption>> GetAccountsAsync(string subscriptionId, CancellationToken cancellationToken = default)
    {
        if (!Guid.TryParse(subscriptionId, out _))
            throw new ArgumentException("A valid Azure subscription ID is required.", nameof(subscriptionId));

        using var document = await GetArmJsonAsync(
            $"https://management.azure.com/subscriptions/{subscriptionId}/resources?api-version=2021-04-01&$filter=resourceType%20eq%20'Microsoft.Automation/automationAccounts'",
            cancellationToken);

        if (!document.RootElement.TryGetProperty("value", out var values))
            return [];

        return values.EnumerateArray()
            .Select(item => new AutomationAccountOption(
                item.GetProperty("id").GetString() ?? string.Empty,
                item.GetProperty("name").GetString() ?? string.Empty,
                GetResourceGroup(item.GetProperty("id").GetString()),
                item.TryGetProperty("location", out var location) ? location.GetString() ?? string.Empty : string.Empty))
            .Where(a => !string.IsNullOrWhiteSpace(a.Id) && !string.IsNullOrWhiteSpace(a.Name))
            .OrderBy(a => a.Name)
            .ToList();
    }

    public async Task<AutomationRunbookValidation> ValidatePublishedRunbookAsync(
        string subscriptionId,
        string resourceGroupName,
        string automationAccountName,
        string runbookName,
        CancellationToken cancellationToken = default)
    {
        var url = $"https://management.azure.com/subscriptions/{Uri.EscapeDataString(subscriptionId)}/resourceGroups/{Uri.EscapeDataString(resourceGroupName)}/providers/Microsoft.Automation/automationAccounts/{Uri.EscapeDataString(automationAccountName)}/runbooks/{Uri.EscapeDataString(runbookName)}?api-version={ApiVersion}";
        using var document = await GetArmJsonAsync(url, cancellationToken);
        var root = document.RootElement;
        var state = root.TryGetProperty("properties", out var properties) && properties.TryGetProperty("state", out var stateElement)
            ? stateElement.GetString()
            : null;
        var type = properties.ValueKind != JsonValueKind.Undefined && properties.TryGetProperty("runbookType", out var typeElement)
            ? typeElement.GetString()
            : null;

        return new AutomationRunbookValidation(
            root.TryGetProperty("id", out var id) ? id.GetString() ?? string.Empty : string.Empty,
            root.TryGetProperty("name", out var name) ? name.GetString() ?? runbookName : runbookName,
            state,
            type,
            string.Equals(state, "Published", StringComparison.OrdinalIgnoreCase));
    }

    private async Task<JsonDocument> GetArmJsonAsync(string url, CancellationToken cancellationToken)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext(ArmScopes), cancellationToken);
        var client = _httpClientFactory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        using var response = await client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Azure Resource Manager returned {(int)response.StatusCode}: {body}");
        return JsonDocument.Parse(body);
    }

    private static string GetResourceGroup(string? armId)
    {
        if (string.IsNullOrWhiteSpace(armId)) return string.Empty;
        var parts = armId.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
            if (parts[i].Equals("resourceGroups", StringComparison.OrdinalIgnoreCase)) return parts[i + 1];
        return string.Empty;
    }
}

public sealed record AutomationAccountOption(string Id, string Name, string ResourceGroup, string Location);
public sealed record AutomationRunbookValidation(string Id, string Name, string? State, string? RunbookType, bool IsPublished);
