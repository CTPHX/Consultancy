using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class HostPoolRefreshService
{
    private const string DesktopVirtualizationApiVersion = "2024-04-03";
    private const string ComputeApiVersion = "2024-03-01";
    private const string NetworkApiVersion = "2024-05-01";
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];

    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly AzureVmImageDiscoveryService _imageDiscovery;
    private readonly EnvironmentConfigurationStore _configurationStore;

    public HostPoolRefreshService(
        TokenCredential credential,
        IHttpClientFactory httpClientFactory,
        AzureVmImageDiscoveryService imageDiscovery,
        EnvironmentConfigurationStore configurationStore)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
        _imageDiscovery = imageDiscovery;
        _configurationStore = configurationStore;
    }

    public async Task<bool> HasChangedAsync(
        SavedHostPoolConfiguration savedPool,
        CancellationToken cancellationToken = default)
    {
        var snapshots = await GetSessionHostSnapshotsAsync(savedPool.HostPoolId, cancellationToken);
        if (snapshots.Count != savedPool.SessionHosts.Count)
            return true;

        foreach (var snapshot in snapshots)
        {
            var saved = savedPool.SessionHosts.FirstOrDefault(h =>
                h.Name.Equals(snapshot.Name, StringComparison.OrdinalIgnoreCase));

            if (saved is null ||
                !string.Equals(saved.Status, snapshot.Status, StringComparison.OrdinalIgnoreCase) ||
                saved.AllowNewSession != snapshot.AllowNewSession ||
                (saved.Sessions ?? 0) != (snapshot.Sessions ?? 0))
                return true;
        }

        return false;
    }

    public async Task<EnvironmentConfiguration> RefreshAsync(
        EnvironmentConfiguration environment,
        string hostPoolId,
        CancellationToken cancellationToken = default)
    {
        var savedPool = environment.HostPools.FirstOrDefault(p =>
            p.HostPoolId.Equals(hostPoolId, StringComparison.OrdinalIgnoreCase));

        if (savedPool is null)
            throw new InvalidOperationException("The selected host pool is not part of the saved environment.");

        var snapshots = await GetSessionHostSnapshotsAsync(savedPool.HostPoolId, cancellationToken);
        var refreshedHosts = new List<SavedSessionHost>();

        foreach (var snapshot in snapshots)
        {
            var existing = savedPool.SessionHosts.FirstOrDefault(h =>
                h.Name.Equals(snapshot.Name, StringComparison.OrdinalIgnoreCase));

            if (existing is not null &&
                !string.IsNullOrWhiteSpace(existing.VmName) &&
                !string.IsNullOrWhiteSpace(existing.VmResourceGroup))
            {
                refreshedHosts.Add(existing with
                {
                    Status = snapshot.Status,
                    AllowNewSession = snapshot.AllowNewSession,
                    Sessions = snapshot.Sessions
                });
                continue;
            }

            refreshedHosts.Add(await BuildSavedSessionHostAsync(snapshot, cancellationToken));
        }

        var now = DateTimeOffset.UtcNow;
        var refreshedPool = savedPool with
        {
            SessionHosts = refreshedHosts.OrderBy(h => h.Name).ToList(),
            LastScannedAtUtc = now
        };

        var updatedEnvironment = environment with
        {
            HostPools = environment.HostPools
                .Select(pool => pool.HostPoolId.Equals(hostPoolId, StringComparison.OrdinalIgnoreCase) ? refreshedPool : pool)
                .ToList()
        };

        await _configurationStore.SaveAsync(updatedEnvironment, cancellationToken);
        return updatedEnvironment;
    }

    private async Task<List<SessionHostSnapshot>> GetSessionHostSnapshotsAsync(
        string hostPoolId,
        CancellationToken cancellationToken)
    {
        var snapshots = new List<SessionHostSnapshot>();
        string? nextUrl = $"https://management.azure.com{hostPoolId}/sessionHosts?api-version={DesktopVirtualizationApiVersion}";

        while (!string.IsNullOrWhiteSpace(nextUrl))
        {
            using var document = await GetArmJsonAsync(nextUrl, cancellationToken);
            if (document.RootElement.TryGetProperty("value", out var values))
            {
                foreach (var item in values.EnumerateArray())
                {
                    var rawName = item.TryGetProperty("name", out var nameElement)
                        ? nameElement.GetString() ?? string.Empty
                        : string.Empty;
                    var name = rawName.Contains('/') ? rawName[(rawName.LastIndexOf('/') + 1)..] : rawName;

                    string? resourceId = null;
                    string? status = null;
                    bool? allowNewSession = null;
                    int? sessions = null;

                    if (item.TryGetProperty("properties", out var properties))
                    {
                        if (properties.TryGetProperty("resourceId", out var resourceIdElement))
                            resourceId = resourceIdElement.GetString();
                        if (properties.TryGetProperty("status", out var statusElement))
                            status = statusElement.GetString();
                        if (properties.TryGetProperty("allowNewSession", out var allowNewSessionElement) &&
                            allowNewSessionElement.ValueKind is JsonValueKind.True or JsonValueKind.False)
                            allowNewSession = allowNewSessionElement.GetBoolean();
                        if (properties.TryGetProperty("sessions", out var sessionsElement) && sessionsElement.TryGetInt32(out var sessionCount))
                            sessions = sessionCount;
                    }

                    snapshots.Add(new SessionHostSnapshot(name, resourceId, status, allowNewSession, sessions));
                }
            }

            nextUrl = document.RootElement.TryGetProperty("nextLink", out var nextLink)
                ? nextLink.GetString()
                : null;
        }

        return snapshots;
    }

    private async Task<SavedSessionHost> BuildSavedSessionHostAsync(
        SessionHostSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        AzureDiscoveredResource? vm = null;
        string? nicName = null;
        string? vnetName = null;
        string? subnetName = null;
        AzureVmImageReference? image = null;

        if (!string.IsNullOrWhiteSpace(snapshot.ResourceId))
        {
            vm = await GetVirtualMachineAsync(snapshot.ResourceId, cancellationToken);
            if (vm is not null)
            {
                (nicName, vnetName, subnetName) = await GetPrimaryNetworkAsync(vm.Id, cancellationToken);
                image = await _imageDiscovery.DiscoverAsync(vm, cancellationToken);
            }
        }

        return new SavedSessionHost(
            Name: snapshot.Name,
            Status: snapshot.Status,
            AllowNewSession: snapshot.AllowNewSession,
            Sessions: snapshot.Sessions,
            VmName: vm?.Name,
            VmResourceGroup: vm?.ResourceGroup,
            NicName: nicName,
            VnetName: vnetName,
            SubnetName: subnetName,
            GalleryName: image?.GalleryName,
            GalleryResourceGroup: image?.GalleryResourceGroup,
            ImageDefinition: image?.ImageDefinitionName,
            ImageVersion: image?.ImageVersionName ?? image?.ExactVersion ?? image?.Version);
    }

    private async Task<AzureDiscoveredResource?> GetVirtualMachineAsync(string resourceId, CancellationToken cancellationToken)
    {
        using var document = await GetArmJsonAsync(
            $"https://management.azure.com{resourceId}?api-version={ComputeApiVersion}", cancellationToken);

        var root = document.RootElement;
        var id = root.TryGetProperty("id", out var idElement) ? idElement.GetString() ?? resourceId : resourceId;
        var name = root.TryGetProperty("name", out var nameElement) ? nameElement.GetString() ?? GetLastArmSegment(resourceId) : GetLastArmSegment(resourceId);
        var location = root.TryGetProperty("location", out var locationElement) ? locationElement.GetString() ?? string.Empty : string.Empty;

        return new AzureDiscoveredResource(
            id,
            name,
            "Microsoft.Compute/virtualMachines",
            location,
            GetResourceGroupFromArmId(id),
            "Virtual Machines",
            null,
            null,
            null);
    }

    private async Task<(string? NicName, string? VnetName, string? SubnetName)> GetPrimaryNetworkAsync(
        string vmId,
        CancellationToken cancellationToken)
    {
        using var vmDocument = await GetArmJsonAsync(
            $"https://management.azure.com{vmId}?api-version={ComputeApiVersion}", cancellationToken);

        if (!vmDocument.RootElement.TryGetProperty("properties", out var vmProperties) ||
            !vmProperties.TryGetProperty("networkProfile", out var networkProfile) ||
            !networkProfile.TryGetProperty("networkInterfaces", out var networkInterfaces))
            return (null, null, null);

        var nicId = networkInterfaces.EnumerateArray()
            .Select(nic => nic.TryGetProperty("id", out var id) ? id.GetString() : null)
            .FirstOrDefault(id => !string.IsNullOrWhiteSpace(id));

        if (string.IsNullOrWhiteSpace(nicId))
            return (null, null, null);

        using var nicDocument = await GetArmJsonAsync(
            $"https://management.azure.com{nicId}?api-version={NetworkApiVersion}", cancellationToken);

        var nicName = nicDocument.RootElement.TryGetProperty("name", out var nicNameElement)
            ? nicNameElement.GetString() ?? GetLastArmSegment(nicId)
            : GetLastArmSegment(nicId);

        if (!nicDocument.RootElement.TryGetProperty("properties", out var nicProperties) ||
            !nicProperties.TryGetProperty("ipConfigurations", out var ipConfigurations))
            return (nicName, null, null);

        foreach (var ipConfig in ipConfigurations.EnumerateArray())
        {
            if (!ipConfig.TryGetProperty("properties", out var ipProperties) ||
                !ipProperties.TryGetProperty("subnet", out var subnet) ||
                !subnet.TryGetProperty("id", out var subnetIdElement))
                continue;

            var subnetId = subnetIdElement.GetString();
            if (string.IsNullOrWhiteSpace(subnetId))
                continue;

            var subnetName = GetLastArmSegment(subnetId);
            var vnetId = GetParentArmId(subnetId, "subnets");
            return (nicName, string.IsNullOrWhiteSpace(vnetId) ? null : GetLastArmSegment(vnetId), subnetName);
        }

        return (nicName, null, null);
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

    private static string? GetParentArmId(string armId, string childTypeSegment)
    {
        var marker = $"/{childTypeSegment}/";
        var index = armId.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        return index > 0 ? armId[..index] : null;
    }

    private static string GetLastArmSegment(string armId) =>
        armId.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? string.Empty;

    private static string GetResourceGroupFromArmId(string armId)
    {
        var parts = armId.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
        {
            if (parts[i].Equals("resourceGroups", StringComparison.OrdinalIgnoreCase))
                return parts[i + 1];
        }

        return string.Empty;
    }

    private sealed record SessionHostSnapshot(
        string Name,
        string? ResourceId,
        string? Status,
        bool? AllowNewSession,
        int? Sessions);
}
