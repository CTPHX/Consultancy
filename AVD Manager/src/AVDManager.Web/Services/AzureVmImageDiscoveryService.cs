using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AzureVmImageDiscoveryService
{
    private const string ComputeApiVersion = "2024-07-01";
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];
    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;

    public AzureVmImageDiscoveryService(TokenCredential credential, IHttpClientFactory httpClientFactory)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
    }

    public async Task<AzureVmImageReference?> DiscoverAsync(
        AzureDiscoveredResource virtualMachine,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(virtualMachine.Id))
            return null;

        using var document = await GetArmJsonAsync(
            $"https://management.azure.com{virtualMachine.Id}?api-version={ComputeApiVersion}",
            cancellationToken);

        if (!document.RootElement.TryGetProperty("properties", out var properties) ||
            !properties.TryGetProperty("storageProfile", out var storageProfile) ||
            !storageProfile.TryGetProperty("imageReference", out var imageReference))
        {
            return null;
        }

        var imageId = GetString(imageReference, "id");
        var publisher = GetString(imageReference, "publisher");
        var offer = GetString(imageReference, "offer");
        var sku = GetString(imageReference, "sku");
        var version = GetString(imageReference, "version");
        var exactVersion = GetString(imageReference, "exactVersion");
        var communityGalleryImageId = GetString(imageReference, "communityGalleryImageId");
        var sharedGalleryImageId = GetString(imageReference, "sharedGalleryImageId");

        string? galleryResourceGroup = null;
        string? galleryName = null;
        string? imageDefinitionName = null;
        string? imageVersionName = null;

        if (!string.IsNullOrWhiteSpace(imageId))
        {
            galleryResourceGroup = GetArmSegmentValue(imageId, "resourceGroups");
            galleryName = GetArmSegmentValue(imageId, "galleries");
            imageDefinitionName = GetArmSegmentValue(imageId, "images");
            imageVersionName = GetArmSegmentValue(imageId, "versions");
        }

        var sourceType = !string.IsNullOrWhiteSpace(galleryName)
            ? "Azure Compute Gallery"
            : !string.IsNullOrWhiteSpace(communityGalleryImageId)
                ? "Community Gallery"
                : !string.IsNullOrWhiteSpace(sharedGalleryImageId)
                    ? "Shared Gallery"
                    : !string.IsNullOrWhiteSpace(publisher) || !string.IsNullOrWhiteSpace(offer) || !string.IsNullOrWhiteSpace(sku)
                        ? "Marketplace"
                        : !string.IsNullOrWhiteSpace(imageId)
                            ? "Azure image resource"
                            : "Unknown";

        return new AzureVmImageReference(
            SourceType: sourceType,
            ImageId: imageId,
            GalleryResourceGroup: galleryResourceGroup,
            GalleryName: galleryName,
            ImageDefinitionName: imageDefinitionName,
            ImageVersionName: imageVersionName,
            Publisher: publisher,
            Offer: offer,
            Sku: sku,
            Version: version,
            ExactVersion: exactVersion,
            CommunityGalleryImageId: communityGalleryImageId,
            SharedGalleryImageId: sharedGalleryImageId);
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

    private static string? GetString(JsonElement element, string propertyName) =>
        element.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : null;

    private static string? GetArmSegmentValue(string armId, string segmentName)
    {
        var parts = armId.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
        {
            if (parts[i].Equals(segmentName, StringComparison.OrdinalIgnoreCase))
                return parts[i + 1];
        }

        return null;
    }
}

public sealed record AzureVmImageReference(
    string SourceType,
    string? ImageId,
    string? GalleryResourceGroup,
    string? GalleryName,
    string? ImageDefinitionName,
    string? ImageVersionName,
    string? Publisher,
    string? Offer,
    string? Sku,
    string? Version,
    string? ExactVersion,
    string? CommunityGalleryImageId,
    string? SharedGalleryImageId);
