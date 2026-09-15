using System.Text.Json;

namespace AVDManager.Web.Services;

public sealed class ImageBuildOperationStore
{
    private readonly string _filePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly JsonSerializerOptions _json = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public ImageBuildOperationStore(IWebHostEnvironment environment)
    {
        _filePath = Path.Combine(environment.ContentRootPath, "App_Data", "image-build-operations.json");
    }

    public async Task<IReadOnlyList<ImageBuildOperation>> ListAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var items = await ReadUnsafeAsync(cancellationToken);
            var cutoff = DateTimeOffset.UtcNow.AddHours(-48);
            items.RemoveAll(x => IsTerminal(x.Status) && x.UpdatedAtUtc < cutoff);
            await WriteUnsafeAsync(items, cancellationToken);
            return items.OrderByDescending(x => x.CreatedAtUtc).ToList();
        }
        finally { _gate.Release(); }
    }

    public async Task AddAsync(ImageBuildOperation operation, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try { var items = await ReadUnsafeAsync(cancellationToken); items.Add(operation); await WriteUnsafeAsync(items, cancellationToken); }
        finally { _gate.Release(); }
    }

    public async Task UpdateAsync(ImageBuildOperation operation, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var items = await ReadUnsafeAsync(cancellationToken);
            var index = items.FindIndex(x => x.Id == operation.Id);
            if (index < 0) throw new InvalidOperationException("Image build operation no longer exists.");
            items[index] = operation;
            await WriteUnsafeAsync(items, cancellationToken);
        }
        finally { _gate.Release(); }
    }

    private static bool IsTerminal(string status) =>
        status.Equals("Completed", StringComparison.OrdinalIgnoreCase) ||
        status.Equals("Failed", StringComparison.OrdinalIgnoreCase) ||
        status.Equals("Cancelled", StringComparison.OrdinalIgnoreCase);

    private async Task<List<ImageBuildOperation>> ReadUnsafeAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_filePath)) return [];
        await using var stream = File.OpenRead(_filePath);
        return await JsonSerializer.DeserializeAsync<List<ImageBuildOperation>>(stream, _json, cancellationToken) ?? [];
    }

    private async Task WriteUnsafeAsync(List<ImageBuildOperation> items, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_filePath)!);
        var temp = _filePath + ".tmp";
        await using (var stream = File.Create(temp)) await JsonSerializer.SerializeAsync(stream, items, _json, cancellationToken);
        File.Move(temp, _filePath, true);
    }
}

public sealed record ImageBuildOperation(
    Guid Id, DateTimeOffset CreatedAtUtc, DateTimeOffset UpdatedAtUtc, string Status,
    string SubscriptionId, string GoldVmId, string GoldVmName, string GoldVmResourceGroup, string Location,
    string GalleryId, string GalleryName, string GalleryResourceGroup, string DefinitionId, string DefinitionName,
    string ImageVersion, string VirtualNetworkId, string VirtualNetworkName, string NetworkResourceGroup,
    string SubnetName, string TempVmSize, int ReplicaCount, IReadOnlyList<string> TargetRegions, bool ExcludeFromLatest,
    string? AutomationJobId = null, string? AutomationJobStatus = null, DateTimeOffset? AutomationSubmittedAtUtc = null,
    string? LastMessage = null, string? ErrorMessage = null, IReadOnlyList<DeploymentAutomationOutputLine>? AutomationOutput = null);
