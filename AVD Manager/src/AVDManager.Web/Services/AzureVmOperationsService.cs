using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AzureVmOperationsService
{
    private const string ComputeApiVersion = "2024-07-01";
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];
    private static readonly TimeSpan OperationTimeout = TimeSpan.FromMinutes(10);

    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;

    public AzureVmOperationsService(TokenCredential credential, IHttpClientFactory httpClientFactory)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
    }

    public Task StartAsync(
        string subscriptionId,
        string resourceGroupName,
        string vmName,
        CancellationToken cancellationToken = default) =>
        SendPowerActionAsync(subscriptionId, resourceGroupName, vmName, "start", cancellationToken);

    public Task DeallocateAsync(
        string subscriptionId,
        string resourceGroupName,
        string vmName,
        CancellationToken cancellationToken = default) =>
        SendPowerActionAsync(subscriptionId, resourceGroupName, vmName, "deallocate", cancellationToken);

    public Task RestartAsync(
        string subscriptionId,
        string resourceGroupName,
        string vmName,
        CancellationToken cancellationToken = default) =>
        SendPowerActionAsync(subscriptionId, resourceGroupName, vmName, "restart", cancellationToken);

    private async Task SendPowerActionAsync(
        string subscriptionId,
        string resourceGroupName,
        string vmName,
        string action,
        CancellationToken cancellationToken)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext(ArmScopes), cancellationToken);
        var client = _httpClientFactory.CreateClient();

        var url = $"https://management.azure.com/subscriptions/{Uri.EscapeDataString(subscriptionId)}/resourceGroups/{Uri.EscapeDataString(resourceGroupName)}/providers/Microsoft.Compute/virtualMachines/{Uri.EscapeDataString(vmName)}/{action}?api-version={ComputeApiVersion}";

        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

        using var response = await client.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
            throw CreateAzureException(response.StatusCode, body);

        if (response.StatusCode != HttpStatusCode.Accepted)
            return;

        var pollUrl = response.Headers.TryGetValues("Azure-AsyncOperation", out var asyncValues)
            ? asyncValues.FirstOrDefault()
            : response.Headers.Location?.ToString();

        if (string.IsNullOrWhiteSpace(pollUrl))
            return;

        await WaitForOperationAsync(client, token.Token, pollUrl, cancellationToken);
    }

    private static async Task WaitForOperationAsync(
        HttpClient client,
        string accessToken,
        string pollUrl,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow.Add(OperationTimeout);

        while (DateTimeOffset.UtcNow < deadline)
        {
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);

            using var request = new HttpRequestMessage(HttpMethod.Get, pollUrl);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

            using var response = await client.SendAsync(request, cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);

            if (!response.IsSuccessStatusCode)
                throw CreateAzureException(response.StatusCode, body);

            var status = TryGetOperationStatus(body);
            if (string.Equals(status, "Succeeded", StringComparison.OrdinalIgnoreCase))
                return;

            if (string.Equals(status, "Failed", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(status, "Canceled", StringComparison.OrdinalIgnoreCase))
            {
                var message = TryGetAzureErrorMessage(body) ?? $"Azure VM operation finished with status {status}.";
                throw new InvalidOperationException(message);
            }

            if (status is null && response.StatusCode == HttpStatusCode.OK)
                return;
        }

        throw new TimeoutException("Azure VM operation did not complete within 10 minutes.");
    }

    private static InvalidOperationException CreateAzureException(HttpStatusCode statusCode, string body)
    {
        var message = TryGetAzureErrorMessage(body) ?? $"Azure Resource Manager returned {(int)statusCode}.";
        return new InvalidOperationException(message);
    }

    private static string? TryGetOperationStatus(string body)
    {
        if (string.IsNullOrWhiteSpace(body))
            return null;

        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.TryGetProperty("status", out var status))
                return status.GetString();
        }
        catch (JsonException)
        {
        }

        return null;
    }

    private static string? TryGetAzureErrorMessage(string body)
    {
        if (string.IsNullOrWhiteSpace(body))
            return null;

        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.TryGetProperty("error", out var error) &&
                error.TryGetProperty("message", out var message))
            {
                return message.GetString();
            }
        }
        catch (JsonException)
        {
        }

        return null;
    }
}
