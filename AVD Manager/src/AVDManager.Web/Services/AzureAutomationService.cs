using System.Net.Http.Headers;
using System.Net.Http.Json;
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
        var url = BuildRunbookUrl(subscriptionId, resourceGroupName, automationAccountName, runbookName);
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

    public async Task<AutomationJobSubmission> SubmitRunbookJobAsync(
        string subscriptionId,
        string resourceGroupName,
        string automationAccountName,
        string runbookName,
        IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken = default)
    {
        var jobId = Guid.NewGuid().ToString();
        var url = BuildJobUrl(subscriptionId, resourceGroupName, automationAccountName, jobId);
        var body = new
        {
            properties = new
            {
                runbook = new { name = runbookName },
                parameters
            }
        };

        using var document = await SendArmJsonAsync(HttpMethod.Put, url, body, cancellationToken);
        var root = document.RootElement;
        var status = TryGetPropertyString(root, "properties", "status") ?? "New";

        return new AutomationJobSubmission(
            root.TryGetProperty("name", out var name) ? name.GetString() ?? jobId : jobId,
            status);
    }

    public async Task<AutomationJobSnapshot> GetJobAsync(
        string subscriptionId,
        string resourceGroupName,
        string automationAccountName,
        string jobId,
        CancellationToken cancellationToken = default)
    {
        using var document = await GetArmJsonAsync(
            BuildJobUrl(subscriptionId, resourceGroupName, automationAccountName, jobId),
            cancellationToken);

        var root = document.RootElement;
        var properties = root.TryGetProperty("properties", out var p) ? p : default;
        var status = properties.ValueKind != JsonValueKind.Undefined && properties.TryGetProperty("status", out var statusElement)
            ? statusElement.GetString() ?? "Unknown"
            : "Unknown";
        var statusDetails = properties.ValueKind != JsonValueKind.Undefined && properties.TryGetProperty("statusDetails", out var detailsElement)
            ? detailsElement.GetString()
            : null;
        var exception = properties.ValueKind != JsonValueKind.Undefined && properties.TryGetProperty("exception", out var exceptionElement)
            ? exceptionElement.GetString()
            : null;

        return new AutomationJobSnapshot(jobId, status, statusDetails, exception);
    }

    public async Task<IReadOnlyList<AutomationJobOutputLine>> GetJobOutputAsync(
        string subscriptionId,
        string resourceGroupName,
        string automationAccountName,
        string jobId,
        CancellationToken cancellationToken = default)
    {
        var lines = new List<AutomationJobOutputLine>();
        string? nextUrl = BuildJobStreamsUrl(subscriptionId, resourceGroupName, automationAccountName, jobId);

        while (!string.IsNullOrWhiteSpace(nextUrl))
        {
            using var document = await GetArmJsonAsync(nextUrl, cancellationToken);
            if (document.RootElement.TryGetProperty("value", out var values) && values.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in values.EnumerateArray())
                {
                    if (!item.TryGetProperty("properties", out var properties))
                        continue;

                    var streamType = properties.TryGetProperty("streamType", out var streamTypeElement)
                        ? streamTypeElement.GetString()
                        : null;

                    var supportedStream = string.Equals(streamType, "Output", StringComparison.OrdinalIgnoreCase) ||
                                          string.Equals(streamType, "Error", StringComparison.OrdinalIgnoreCase) ||
                                          string.Equals(streamType, "Warning", StringComparison.OrdinalIgnoreCase) ||
                                          string.Equals(streamType, "Verbose", StringComparison.OrdinalIgnoreCase);
                    if (!supportedStream)
                        continue;

                    var text = properties.TryGetProperty("streamText", out var textElement)
                        ? textElement.GetString()
                        : null;

                    if (string.IsNullOrWhiteSpace(text))
                        continue;

                    DateTimeOffset? time = null;
                    if (properties.TryGetProperty("time", out var timeElement) &&
                        DateTimeOffset.TryParse(timeElement.GetString(), out var parsed))
                        time = parsed;

                    var streamId = properties.TryGetProperty("jobStreamId", out var streamIdElement)
                        ? streamIdElement.GetString()
                        : item.TryGetProperty("name", out var nameElement) ? nameElement.GetString() : null;

                    lines.Add(new AutomationJobOutputLine(
                        streamId ?? Guid.NewGuid().ToString(),
                        time,
                        string.Equals(streamType, "Output", StringComparison.OrdinalIgnoreCase)
                            ? text
                            : $"[{streamType}] {text}"));
                }
            }

            nextUrl = document.RootElement.TryGetProperty("nextLink", out var nextLink)
                ? nextLink.GetString()
                : null;
        }

        return lines
            .OrderBy(line => line.TimeUtc ?? DateTimeOffset.MinValue)
            .ThenBy(line => line.StreamId, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private string BuildRunbookUrl(string subscriptionId, string resourceGroupName, string automationAccountName, string runbookName) =>
        $"https://management.azure.com/subscriptions/{Uri.EscapeDataString(subscriptionId)}/resourceGroups/{Uri.EscapeDataString(resourceGroupName)}/providers/Microsoft.Automation/automationAccounts/{Uri.EscapeDataString(automationAccountName)}/runbooks/{Uri.EscapeDataString(runbookName)}?api-version={ApiVersion}";

    private string BuildJobUrl(string subscriptionId, string resourceGroupName, string automationAccountName, string jobId) =>
        $"https://management.azure.com/subscriptions/{Uri.EscapeDataString(subscriptionId)}/resourceGroups/{Uri.EscapeDataString(resourceGroupName)}/providers/Microsoft.Automation/automationAccounts/{Uri.EscapeDataString(automationAccountName)}/jobs/{Uri.EscapeDataString(jobId)}?api-version={ApiVersion}";

    private string BuildJobStreamsUrl(string subscriptionId, string resourceGroupName, string automationAccountName, string jobId) =>
        $"https://management.azure.com/subscriptions/{Uri.EscapeDataString(subscriptionId)}/resourceGroups/{Uri.EscapeDataString(resourceGroupName)}/providers/Microsoft.Automation/automationAccounts/{Uri.EscapeDataString(automationAccountName)}/jobs/{Uri.EscapeDataString(jobId)}/streams?api-version={ApiVersion}";

    private async Task<JsonDocument> GetArmJsonAsync(string url, CancellationToken cancellationToken) =>
        await SendArmJsonAsync(HttpMethod.Get, url, null, cancellationToken);

    private async Task<JsonDocument> SendArmJsonAsync(HttpMethod method, string url, object? body, CancellationToken cancellationToken)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext(ArmScopes), cancellationToken);
        var client = _httpClientFactory.CreateClient();
        using var request = new HttpRequestMessage(method, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        if (body is not null)
            request.Content = JsonContent.Create(body);

        using var response = await client.SendAsync(request, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Azure Resource Manager returned {(int)response.StatusCode}: {responseBody}");

        return string.IsNullOrWhiteSpace(responseBody)
            ? JsonDocument.Parse("{}")
            : JsonDocument.Parse(responseBody);
    }

    private static string? TryGetPropertyString(JsonElement root, string parentName, string propertyName)
    {
        if (!root.TryGetProperty(parentName, out var parent) || !parent.TryGetProperty(propertyName, out var property))
            return null;
        return property.GetString();
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
public sealed record AutomationJobSubmission(string JobId, string Status);
public sealed record AutomationJobSnapshot(string JobId, string Status, string? StatusDetails, string? Exception);
public sealed record AutomationJobOutputLine(string StreamId, DateTimeOffset? TimeUtc, string Text);
