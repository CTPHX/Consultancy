using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AzureVmOperationsService
{
    private const string ComputeApiVersion = "2024-07-01";
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];

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

        if (response.IsSuccessStatusCode)
            return;

        var message = TryGetAzureErrorMessage(body) ?? $"Azure Resource Manager returned {(int)response.StatusCode}.";
        throw new InvalidOperationException(message);
    }

    private static string? TryGetAzureErrorMessage(string body)
    {
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
