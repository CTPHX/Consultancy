using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AvdUserSessionService
{
    private const string ArmScope = "https://management.azure.com/.default";
    private const string ApiVersion = "2024-04-03";
    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;

    public AvdUserSessionService(TokenCredential credential, IHttpClientFactory httpClientFactory)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
    }

    public async Task<IReadOnlyList<AvdUserSession>> ListByHostPoolAsync(string subscriptionId, string resourceGroup, string hostPoolName, CancellationToken cancellationToken = default)
    {
        var sessions = new List<AvdUserSession>();
        var nextUrl = $"https://management.azure.com/subscriptions/{Uri.EscapeDataString(subscriptionId)}/resourceGroups/{Uri.EscapeDataString(resourceGroup)}/providers/Microsoft.DesktopVirtualization/hostPools/{Uri.EscapeDataString(hostPoolName)}/userSessions?api-version={ApiVersion}";

        while (!string.IsNullOrWhiteSpace(nextUrl))
        {
            using var response = await SendAsync(HttpMethod.Get, nextUrl, cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException(GetAzureError(body, $"Azure returned {(int)response.StatusCode} while reading user sessions."));

            using var document = JsonDocument.Parse(body);
            if (document.RootElement.TryGetProperty("value", out var values) && values.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in values.EnumerateArray())
                {
                    var resourceId = GetString(item, "id");
                    var sessionId = GetString(item, "name");
                    if (string.IsNullOrWhiteSpace(resourceId) || string.IsNullOrWhiteSpace(sessionId)) continue;

                    var properties = item.TryGetProperty("properties", out var props) ? props : default;
                    sessions.Add(new AvdUserSession(
                        resourceId,
                        sessionId,
                        GetResourceName(resourceId, "sessionHosts") ?? "Unknown host",
                        GetString(properties, "userPrincipalName") ?? GetString(properties, "activeDirectoryUserName") ?? "Unknown user",
                        GetString(properties, "activeDirectoryUserName"),
                        GetString(properties, "sessionState") ?? "Unknown",
                        GetString(properties, "applicationType"),
                        GetDateTimeOffset(properties, "createTime")));
                }
            }

            nextUrl = GetString(document.RootElement, "nextLink");
        }

        return sessions
            .OrderBy(session => session.SessionHostName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(session => session.UserPrincipalName, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public async Task LogoffAsync(string userSessionResourceId, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(userSessionResourceId) || !userSessionResourceId.StartsWith("/subscriptions/", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("A valid AVD user session resource ID is required.", nameof(userSessionResourceId));

        var url = $"https://management.azure.com{userSessionResourceId}?api-version={ApiVersion}&force=true";
        using var response = await SendAsync(HttpMethod.Delete, url, cancellationToken);
        if (response.IsSuccessStatusCode) return;

        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        throw new InvalidOperationException(GetAzureError(body, $"Azure returned {(int)response.StatusCode} while logging off the user session."));
    }

    private async Task<HttpResponseMessage> SendAsync(HttpMethod method, string url, CancellationToken cancellationToken)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext([ArmScope]), cancellationToken);
        var client = _httpClientFactory.CreateClient();
        using var request = new HttpRequestMessage(method, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        return await client.SendAsync(request, cancellationToken);
    }

    private static string? GetResourceName(string resourceId, string resourceType)
    {
        var parts = resourceId.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
            if (parts[i].Equals(resourceType, StringComparison.OrdinalIgnoreCase)) return Uri.UnescapeDataString(parts[i + 1]);
        return null;
    }

    private static string? GetString(JsonElement element, string propertyName)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(propertyName, out var property) || property.ValueKind != JsonValueKind.String) return null;
        return property.GetString();
    }

    private static DateTimeOffset? GetDateTimeOffset(JsonElement element, string propertyName)
    {
        var value = GetString(element, propertyName);
        return DateTimeOffset.TryParse(value, out var parsed) ? parsed : null;
    }

    private static string GetAzureError(string body, string fallback)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.TryGetProperty("error", out var error) && error.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String)
                return message.GetString() ?? fallback;
        }
        catch (JsonException) { }
        return fallback;
    }
}

public sealed record AvdUserSession(
    string ResourceId,
    string SessionId,
    string SessionHostName,
    string UserPrincipalName,
    string? ActiveDirectoryUserName,
    string SessionState,
    string? ApplicationType,
    DateTimeOffset? CreateTimeUtc);
