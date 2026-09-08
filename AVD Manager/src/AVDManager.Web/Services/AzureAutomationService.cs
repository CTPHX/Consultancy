using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AzureAutomationService
{
    private const string ResourceApiVersion = "2021-04-01";
    private const string AutomationApiVersion = "2023-11-01";
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];

    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;

    public AzureAutomationService(TokenCredential credential, IHttpClientFactory httpClientFactory)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
    }

    public async Task<AutomationJobSubmission> StartRunbookAsync(
        string subscriptionId,
        string automationResourceGroup,
        string runbookName,
        IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(automationResourceGroup))
            throw new InvalidOperationException("No Automation resource group is configured for this host pool.");

        var automationAccountName = await ResolveAutomationAccountAsync(
            subscriptionId,
            automationResourceGroup,
            cancellationToken);

        var jobName = Guid.NewGuid().ToString();
        var url = $"https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{Uri.EscapeDataString(automationResourceGroup)}/providers/Microsoft.Automation/automationAccounts/{Uri.EscapeDataString(automationAccountName)}/jobs/{jobName}?api-version={AutomationApiVersion}";

        var payload = JsonSerializer.Serialize(new
        {
            properties = new
            {
                runbook = new { name = runbookName },
                parameters,
                runOn = string.Empty
            }
        });

        var token = await _credential.GetTokenAsync(new TokenRequestContext(ArmScopes), cancellationToken);
        var client = _httpClientFactory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Put, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        request.Content = new StringContent(payload, Encoding.UTF8, "application/json");

        using var response = await client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Azure Automation returned {(int)response.StatusCode}: {body}");

        using var document = JsonDocument.Parse(body);
        var status = document.RootElement.TryGetProperty("properties", out var properties) &&
                     properties.TryGetProperty("status", out var statusElement)
            ? statusElement.GetString()
            : null;

        return new AutomationJobSubmission(jobName, automationAccountName, status ?? "Submitted");
    }

    private async Task<string> ResolveAutomationAccountAsync(
        string subscriptionId,
        string automationResourceGroup,
        CancellationToken cancellationToken)
    {
        var url = $"https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{Uri.EscapeDataString(automationResourceGroup)}/resources?api-version={ResourceApiVersion}&$filter=resourceType eq 'Microsoft.Automation/automationAccounts'";
        var token = await _credential.GetTokenAsync(new TokenRequestContext(ArmScopes), cancellationToken);
        var client = _httpClientFactory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

        using var response = await client.GetAsync(url, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Could not discover the Automation Account. Azure Resource Manager returned {(int)response.StatusCode}: {body}");

        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("value", out var values))
            throw new InvalidOperationException("No Automation Account was found in the configured Automation resource group.");

        var accounts = values.EnumerateArray()
            .Select(item => item.TryGetProperty("name", out var name) ? name.GetString() : null)
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Cast<string>()
            .ToList();

        return accounts.Count switch
        {
            1 => accounts[0],
            0 => throw new InvalidOperationException($"No Automation Account was found in resource group '{automationResourceGroup}'."),
            _ => throw new InvalidOperationException($"More than one Automation Account was found in resource group '{automationResourceGroup}'. AVD Manager needs an explicit Automation Account mapping before it can submit operational jobs.")
        };
    }
}

public sealed record AutomationJobSubmission(
    string JobName,
    string AutomationAccountName,
    string Status);
