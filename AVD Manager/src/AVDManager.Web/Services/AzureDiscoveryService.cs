using System.Net.Http.Headers;
using System.Text.Json;
using Azure.Core;

namespace AVDManager.Web.Services;

public sealed class AzureDiscoveryService
{
    private const string DesktopVirtualizationApiVersion = "2024-04-03";
    private static readonly string[] ArmScopes = ["https://management.azure.com/.default"];
    private readonly TokenCredential _credential;
    private readonly IHttpClientFactory _httpClientFactory;

    public AzureDiscoveryService(TokenCredential credential, IHttpClientFactory httpClientFactory)
    {
        _credential = credential;
        _httpClientFactory = httpClientFactory;
    }

    public async Task<IReadOnlyList<AzureSubscription>> GetSubscriptionsAsync(CancellationToken cancellationToken = default)
    {
        using var document = await GetArmJsonAsync(
            "https://management.azure.com/subscriptions?api-version=2022-12-01",
            cancellationToken);

        var subscriptions = new List<AzureSubscription>();
        if (!document.RootElement.TryGetProperty("value", out var values))
            return subscriptions;

        foreach (var item in values.EnumerateArray())
        {
            subscriptions.Add(new AzureSubscription(
                item.GetProperty("subscriptionId").GetString() ?? string.Empty,
                item.GetProperty("displayName").GetString() ?? "Unnamed subscription",
                item.TryGetProperty("state", out var state) ? state.GetString() ?? "Unknown" : "Unknown"));
        }

        return subscriptions.OrderBy(s => s.DisplayName).ToList();
    }

    public async Task<AzureDiscoveryResult> DiscoverSubscriptionAsync(
        string subscriptionId,
        CancellationToken cancellationToken = default)
    {
        if (!Guid.TryParse(subscriptionId, out _))
            throw new ArgumentException("A valid Azure subscription ID is required.", nameof(subscriptionId));

        var subscriptions = await GetSubscriptionsAsync(cancellationToken);
        var subscription = subscriptions.FirstOrDefault(s =>
            string.Equals(s.SubscriptionId, subscriptionId, StringComparison.OrdinalIgnoreCase));

        if (subscription is null)
            throw new InvalidOperationException("The AVD Manager application identity cannot access that subscription.");

        var resources = new List<AzureDiscoveredResource>();
        string? nextUrl = $"https://management.azure.com/subscriptions/{subscriptionId}/resources?api-version=2021-04-01";

        while (!string.IsNullOrWhiteSpace(nextUrl))
        {
            using var document = await GetArmJsonAsync(nextUrl, cancellationToken);
            if (document.RootElement.TryGetProperty("value", out var values))
            {
                foreach (var item in values.EnumerateArray())
                {
                    var type = item.TryGetProperty("type", out var typeElement)
                        ? typeElement.GetString() ?? string.Empty
                        : string.Empty;

                    var category = Categorise(type);
                    if (category is null)
                        continue;

                    resources.Add(new AzureDiscoveredResource(
                        item.TryGetProperty("id", out var id) ? id.GetString() ?? string.Empty : string.Empty,
                        item.TryGetProperty("name", out var name) ? name.GetString() ?? "Unnamed resource" : "Unnamed resource",
                        type,
                        item.TryGetProperty("location", out var location) ? location.GetString() ?? "Global" : "Global",
                        GetResourceGroup(item),
                        category,
                        HostPoolArmPath: null,
                        WorkspaceArmPath: null,
                        ApplicationGroupType: null));
                }
            }

            nextUrl = document.RootElement.TryGetProperty("nextLink", out var nextLink)
                ? nextLink.GetString()
                : null;
        }

        resources = await EnrichAvdApplicationGroupsAsync(resources, cancellationToken);
        var sessionHosts = await DiscoverAvdSessionHostsAsync(resources, cancellationToken);

        return new AzureDiscoveryResult(
            subscription,
            resources
                .OrderBy(r => r.Category)
                .ThenBy(r => r.Name)
                .ToList(),
            sessionHosts
                .OrderBy(h => h.HostPoolArmPath)
                .ThenBy(h => h.Name)
                .ToList());
    }

    private async Task<List<AzureDiscoveredResource>> EnrichAvdApplicationGroupsAsync(
        List<AzureDiscoveredResource> resources,
        CancellationToken cancellationToken)
    {
        var enriched = new List<AzureDiscoveredResource>(resources.Count);

        foreach (var resource in resources)
        {
            if (resource.Category != "AVD Application Groups" || string.IsNullOrWhiteSpace(resource.Id))
            {
                enriched.Add(resource);
                continue;
            }

            using var document = await GetArmJsonAsync(
                $"https://management.azure.com{resource.Id}?api-version={DesktopVirtualizationApiVersion}",
                cancellationToken);

            string? hostPoolArmPath = null;
            string? workspaceArmPath = null;
            string? applicationGroupType = null;

            if (document.RootElement.TryGetProperty("properties", out var properties))
            {
                if (properties.TryGetProperty("hostPoolArmPath", out var hostPool))
                    hostPoolArmPath = hostPool.GetString();
                if (properties.TryGetProperty("workspaceArmPath", out var workspace))
                    workspaceArmPath = workspace.GetString();
                if (properties.TryGetProperty("applicationGroupType", out var appType))
                    applicationGroupType = appType.GetString();
            }

            enriched.Add(resource with
            {
                HostPoolArmPath = hostPoolArmPath,
                WorkspaceArmPath = workspaceArmPath,
                ApplicationGroupType = applicationGroupType
            });
        }

        return enriched;
    }

    private async Task<List<AzureSessionHost>> DiscoverAvdSessionHostsAsync(
        IReadOnlyList<AzureDiscoveredResource> resources,
        CancellationToken cancellationToken)
    {
        var discovered = new List<AzureSessionHost>();
        var hostPools = resources.Where(r => r.Category == "AVD Host Pools" && !string.IsNullOrWhiteSpace(r.Id));
        var virtualMachines = resources.Where(r => r.Category == "Virtual Machines").ToList();

        foreach (var hostPool in hostPools)
        {
            string? nextUrl = $"https://management.azure.com{hostPool.Id}/sessionHosts?api-version={DesktopVirtualizationApiVersion}";

            while (!string.IsNullOrWhiteSpace(nextUrl))
            {
                using var document = await GetArmJsonAsync(nextUrl, cancellationToken);
                if (document.RootElement.TryGetProperty("value", out var values))
                {
                    foreach (var item in values.EnumerateArray())
                    {
                        var id = item.TryGetProperty("id", out var idElement) ? idElement.GetString() ?? string.Empty : string.Empty;
                        var rawName = item.TryGetProperty("name", out var nameElement) ? nameElement.GetString() ?? string.Empty : string.Empty;
                        var name = rawName.Contains('/') ? rawName[(rawName.LastIndexOf('/') + 1)..] : rawName;

                        string? resourceId = null;
                        string? virtualMachineId = null;
                        string? status = null;
                        string? statusTimestamp = null;
                        bool? allowNewSession = null;
                        int? sessions = null;

                        if (item.TryGetProperty("properties", out var properties))
                        {
                            if (properties.TryGetProperty("resourceId", out var resourceIdElement))
                                resourceId = resourceIdElement.GetString();
                            if (properties.TryGetProperty("virtualMachineId", out var vmIdElement))
                                virtualMachineId = vmIdElement.GetString();
                            if (properties.TryGetProperty("status", out var statusElement))
                                status = statusElement.GetString();
                            if (properties.TryGetProperty("statusTimestamp", out var statusTimestampElement))
                                statusTimestamp = statusTimestampElement.GetString();
                            if (properties.TryGetProperty("allowNewSession", out var allowNewSessionElement) &&
                                (allowNewSessionElement.ValueKind == JsonValueKind.True || allowNewSessionElement.ValueKind == JsonValueKind.False))
                                allowNewSession = allowNewSessionElement.GetBoolean();
                            if (properties.TryGetProperty("sessions", out var sessionsElement) && sessionsElement.TryGetInt32(out var sessionCount))
                                sessions = sessionCount;
                        }

                        var backingVm = FindBackingVirtualMachine(virtualMachines, resourceId, name);

                        discovered.Add(new AzureSessionHost(
                            id,
                            name,
                            hostPool.Id,
                            resourceId,
                            virtualMachineId,
                            status,
                            statusTimestamp,
                            allowNewSession,
                            sessions,
                            backingVm));
                    }
                }

                nextUrl = document.RootElement.TryGetProperty("nextLink", out var nextLink)
                    ? nextLink.GetString()
                    : null;
            }
        }

        return discovered;
    }

    private static AzureDiscoveredResource? FindBackingVirtualMachine(
        IReadOnlyList<AzureDiscoveredResource> virtualMachines,
        string? resourceId,
        string sessionHostName)
    {
        if (!string.IsNullOrWhiteSpace(resourceId))
        {
            var exact = virtualMachines.FirstOrDefault(vm => ArmIdEquals(vm.Id, resourceId));
            if (exact is not null)
                return exact;
        }

        var shortHostName = sessionHostName.Split('.', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        if (string.IsNullOrWhiteSpace(shortHostName))
            return null;

        return virtualMachines.FirstOrDefault(vm =>
            vm.Name.Equals(shortHostName, StringComparison.OrdinalIgnoreCase));
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

    private static bool ArmIdEquals(string? left, string? right) =>
        string.Equals(left?.TrimEnd('/'), right?.TrimEnd('/'), StringComparison.OrdinalIgnoreCase);

    private static string GetResourceGroup(JsonElement item)
    {
        if (!item.TryGetProperty("id", out var idElement))
            return string.Empty;

        var id = idElement.GetString();
        if (string.IsNullOrWhiteSpace(id))
            return string.Empty;

        var parts = id.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
        {
            if (parts[i].Equals("resourceGroups", StringComparison.OrdinalIgnoreCase))
                return parts[i + 1];
        }

        return string.Empty;
    }

    private static string? Categorise(string resourceType)
    {
        var type = resourceType.ToLowerInvariant();

        if (type.StartsWith("microsoft.desktopvirtualization/hostpools")) return "AVD Host Pools";
        if (type.StartsWith("microsoft.desktopvirtualization/workspaces")) return "AVD Workspaces";
        if (type.StartsWith("microsoft.desktopvirtualization/applicationgroups")) return "AVD Application Groups";
        if (type.StartsWith("microsoft.desktopvirtualization/scalingplans")) return "AVD Scaling Plans";
        if (type == "microsoft.compute/virtualmachines") return "Virtual Machines";
        if (type == "microsoft.compute/galleries") return "Compute Galleries";
        if (type.StartsWith("microsoft.compute/galleries/images/versions")) return "Gallery Image Versions";
        if (type.StartsWith("microsoft.compute/galleries/images")) return "Gallery Images";
        if (type == "microsoft.storage/storageaccounts") return "Storage Accounts";
        if (type == "microsoft.automation/automationaccounts") return "Automation Accounts";
        if (type == "microsoft.keyvault/vaults") return "Key Vaults";
        if (type == "microsoft.network/virtualnetworks") return "Virtual Networks";
        if (type == "microsoft.network/networkinterfaces") return "Network Interfaces";

        return null;
    }
}

public sealed record AzureSubscription(string SubscriptionId, string DisplayName, string State);

public sealed record AzureDiscoveredResource(
    string Id,
    string Name,
    string Type,
    string Location,
    string ResourceGroup,
    string Category,
    string? HostPoolArmPath,
    string? WorkspaceArmPath,
    string? ApplicationGroupType);

public sealed record AzureSessionHost(
    string Id,
    string Name,
    string HostPoolArmPath,
    string? ResourceId,
    string? VirtualMachineId,
    string? Status,
    string? StatusTimestamp,
    bool? AllowNewSession,
    int? Sessions,
    AzureDiscoveredResource? VirtualMachine);

public sealed record AzureDiscoveryResult(
    AzureSubscription Subscription,
    IReadOnlyList<AzureDiscoveredResource> Resources,
    IReadOnlyList<AzureSessionHost> SessionHosts);
