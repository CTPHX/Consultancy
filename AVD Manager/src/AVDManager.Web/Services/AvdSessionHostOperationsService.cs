using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AvdSessionHostOperationsService
{
    private const string DesktopVirtualizationApiVersion = "2024-04-03";
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];

    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;

    public AvdSessionHostOperationsService(TokenCredential credential, IHttpClientFactory httpClientFactory)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
    }

    public async Task SetAllowNewSessionAsync(
        string subscriptionId,
        string resourceGroupName,
        string hostPoolName,
        string sessionHostName,
        bool allowNewSession,
        CancellationToken cancellationToken = default)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext(ArmScopes), cancellationToken);
        var client = _httpClientFactory.CreateClient();

        var url = $"https://management.azure.com/subscriptions/{Uri.EscapeDataString(subscriptionId)}/resourceGroups/{Uri.EscapeDataString(resourceGroupName)}/providers/Microsoft.DesktopVirtualization/hostPools/{Uri.EscapeDataString(hostPoolName)}/sessionHosts/{Uri.EscapeDataString(sessionHostName)}?api-version={DesktopVirtualizationApiVersion}";

        var payload = JsonSerializer.Serialize(new
        {
            properties = new
            {
                allowNewSession
            }
        });

        using var request = new HttpRequestMessage(HttpMethod.Patch, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        request.Content = new StringContent(payload, Encoding.UTF8, "application/json");

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
