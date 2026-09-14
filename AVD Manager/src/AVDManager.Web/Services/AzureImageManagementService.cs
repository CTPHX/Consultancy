using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AzureImageManagementService
{
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];
    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;

    public AzureImageManagementService(TokenCredential credential, IHttpClientFactory httpClientFactory)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
    }

    public async Task<ImageManagementDiscovery> DiscoverAsync(string subscriptionId, CancellationToken cancellationToken = default)
    {
        var vms = await ListAsync(subscriptionId, "Microsoft.Compute/virtualMachines", "2024-07-01", cancellationToken);
        var galleries = await ListAsync(subscriptionId, "Microsoft.Compute/galleries", "2023-07-03", cancellationToken);
        var definitions = await ListAsync(subscriptionId, "Microsoft.Compute/galleries/images", "2023-07-03", cancellationToken);
        // Gallery image versions are child resources and are not reliably returned by the generic
        // subscription /resources query. Enumerate each discovered image definition directly.
        var versions = new List<JsonElement>();
        foreach (var definition in definitions)
        {
            var definitionId = Get(definition, "id");
            if (!string.IsNullOrWhiteSpace(definitionId))
                versions.AddRange(await ListChildResourcesAsync(definitionId, "versions", "2023-07-03", cancellationToken));
        }
        var vnets = await ListAsync(subscriptionId, "Microsoft.Network/virtualNetworks", "2024-05-01", cancellationToken);

        return new ImageManagementDiscovery(
            vms.Where(IsGoldImageVm).Select(ToResource).OrderBy(x => x.Name).ToList(),
            galleries.Select(ToResource).OrderBy(x => x.Name).ToList(),
            definitions.Select(ToGalleryDefinition).OrderBy(x => x.GalleryName).ThenBy(x => x.Name).ToList(),
            versions.Select(ToGalleryVersion).OrderBy(x => x.GalleryName).ThenBy(x => x.DefinitionName).ThenByDescending(x => ParseVersion(x.Name)).ToList(),
            vnets.Select(ToResource).OrderBy(x => x.Name).ToList());
    }

    private async Task<List<JsonElement>> ListAsync(string subscriptionId, string resourceType, string apiVersion, CancellationToken cancellationToken)
    {
        var results = new List<JsonElement>();
        string? url = $"https://management.azure.com/subscriptions/{subscriptionId}/resources?$filter=resourceType eq '{resourceType}'&api-version=2021-04-01";

        while (!string.IsNullOrWhiteSpace(url))
        {
            using var doc = await GetAsync(url, cancellationToken);
            if (doc.RootElement.TryGetProperty("value", out var values))
                results.AddRange(values.EnumerateArray().Select(x => x.Clone()));
            url = doc.RootElement.TryGetProperty("nextLink", out var next) ? next.GetString() : null;
        }
        return results;
    }

    private async Task<List<JsonElement>> ListChildResourcesAsync(string parentResourceId, string childType, string apiVersion, CancellationToken cancellationToken)
    {
        var results = new List<JsonElement>();
        string? url = $"https://management.azure.com{parentResourceId}/{childType}?api-version={apiVersion}";

        while (!string.IsNullOrWhiteSpace(url))
        {
            using var doc = await GetAsync(url, cancellationToken);
            if (doc.RootElement.TryGetProperty("value", out var values))
                results.AddRange(values.EnumerateArray().Select(x => x.Clone()));
            url = doc.RootElement.TryGetProperty("nextLink", out var next) ? next.GetString() : null;
        }

        return results;
    }

    public async Task<IReadOnlyList<AzureSubnetOption>> GetSubnetsAsync(string vnetId, CancellationToken cancellationToken = default)
    {
        using var doc = await GetAsync($"https://management.azure.com{vnetId}?api-version=2024-05-01", cancellationToken);
        var result = new List<AzureSubnetOption>();
        if (doc.RootElement.TryGetProperty("properties", out var properties) && properties.TryGetProperty("subnets", out var subnets))
        {
            foreach (var subnet in subnets.EnumerateArray())
            {
                var name = subnet.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
                var id = subnet.TryGetProperty("id", out var i) ? i.GetString() ?? "" : "";
                if (!string.IsNullOrWhiteSpace(name) && !string.IsNullOrWhiteSpace(id)) result.Add(new(id, name));
            }
        }
        return result;
    }

    private async Task<JsonDocument> GetAsync(string url, CancellationToken cancellationToken)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext(ArmScopes), cancellationToken);
        var client = _httpClientFactory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        using var response = await client.GetAsync(url, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"Azure Resource Manager returned {(int)response.StatusCode}: {body}");
        return JsonDocument.Parse(body);
    }

    private static bool IsGoldImageVm(JsonElement item)
    {
        if (!item.TryGetProperty("tags", out var tags) || tags.ValueKind != JsonValueKind.Object)
            return false;

        foreach (var tag in tags.EnumerateObject())
        {
            if (tag.Name.Equals("AVDManager", StringComparison.OrdinalIgnoreCase) &&
                string.Equals(tag.Value.GetString(), "GoldImage", StringComparison.OrdinalIgnoreCase))
                return true;
        }

        return false;
    }

    private static AzureImageResource ToResource(JsonElement item) =>
        new(Get(item, "id"), Get(item, "name"), Get(item, "location"), ResourceGroup(Get(item, "id")));

    private static AzureGalleryDefinition ToGalleryDefinition(JsonElement item)
    {
        var id = Get(item, "id");
        return new(id, Get(item, "name"), ParentName(id, "galleries"), Get(item, "location"), ResourceGroup(id));
    }

    private static AzureGalleryVersion ToGalleryVersion(JsonElement item)
    {
        var id = Get(item, "id");
        // Resource IDs contain both ".../galleries/{gallery}/images/{definition}/versions/{version}".
        // ParentName("images") can accidentally match the resource-group name (for example
        // "rg-avd-images-uks"), so parse the gallery/definition pair relative to the galleries segment.
        var parts = id.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var galleryIndex = Array.FindIndex(parts, x => x.Equals("galleries", StringComparison.OrdinalIgnoreCase));
        var galleryName = galleryIndex >= 0 && galleryIndex + 1 < parts.Length ? parts[galleryIndex + 1] : "";
        var definitionName = galleryIndex >= 0 && galleryIndex + 3 < parts.Length &&
                             parts[galleryIndex + 2].Equals("images", StringComparison.OrdinalIgnoreCase)
            ? parts[galleryIndex + 3]
            : "";
        return new(id, Get(item, "name"), galleryName, definitionName, Get(item, "location"), ResourceGroup(id));
    }

    private static string Get(JsonElement item, string name) => item.TryGetProperty(name, out var value) ? value.GetString() ?? "" : "";
    private static string ResourceGroup(string id)
    {
        var parts = id.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var i = Array.FindIndex(parts, x => x.Equals("resourceGroups", StringComparison.OrdinalIgnoreCase));
        return i >= 0 && i + 1 < parts.Length ? parts[i + 1] : "";
    }
    private static string ParentName(string id, string segment)
    {
        var parts = id.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var i = Array.FindIndex(parts, x => x.Equals(segment, StringComparison.OrdinalIgnoreCase));
        return i >= 0 && i + 1 < parts.Length ? parts[i + 1] : "";
    }
    private static string ChildName(string id, string segment)
    {
        var parts = id.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var i = Array.FindLastIndex(parts, x => x.Equals(segment, StringComparison.OrdinalIgnoreCase));
        return i >= 0 && i + 1 < parts.Length ? parts[i + 1] : "";
    }
    private static Version ParseVersion(string value) => Version.TryParse(value, out var v) ? v : new Version(0,0,0);
}

public sealed record ImageManagementDiscovery(
    IReadOnlyList<AzureImageResource> VirtualMachines,
    IReadOnlyList<AzureImageResource> Galleries,
    IReadOnlyList<AzureGalleryDefinition> Definitions,
    IReadOnlyList<AzureGalleryVersion> Versions,
    IReadOnlyList<AzureImageResource> VirtualNetworks);
public sealed record AzureImageResource(string Id, string Name, string Location, string ResourceGroup);
public sealed record AzureGalleryDefinition(string Id, string Name, string GalleryName, string Location, string ResourceGroup);
public sealed record AzureGalleryVersion(string Id, string Name, string GalleryName, string DefinitionName, string Location, string ResourceGroup);
public sealed record AzureSubnetOption(string Id, string Name);
