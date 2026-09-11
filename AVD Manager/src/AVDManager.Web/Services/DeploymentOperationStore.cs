using System.Text.Json;

namespace AVDManager.Web.Services;

public sealed class DeploymentOperationStore
{
    private readonly string _filePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly JsonSerializerOptions _json = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public DeploymentOperationStore(IWebHostEnvironment environment)
    {
        _filePath = Path.Combine(environment.ContentRootPath, "App_Data", "deployment-operations.json");
    }

    public async Task<IReadOnlyList<DeploymentOperation>> ListAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var items = await ReadUnsafeAsync(cancellationToken);
            var cutoff = DateTimeOffset.UtcNow.AddHours(-48);
            var removed = items.RemoveAll(x => IsTerminal(x.Status) && x.UpdatedAtUtc < cutoff);
            if (removed > 0) await WriteUnsafeAsync(items, cancellationToken);
            return items.OrderByDescending(x => x.CreatedAtUtc).ToList();
        }
        finally { _gate.Release(); }
    }

    private static bool IsTerminal(string status) =>
        status.Equals("Completed", StringComparison.OrdinalIgnoreCase) ||
        status.Equals("Cancelled", StringComparison.OrdinalIgnoreCase) ||
        status.Equals("Failed", StringComparison.OrdinalIgnoreCase);

    public async Task AddAsync(DeploymentOperation operation, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var items = await ReadUnsafeAsync(cancellationToken);
            items.Add(operation);
            await WriteUnsafeAsync(items, cancellationToken);
        }
        finally { _gate.Release(); }
    }

    public async Task UpdateAsync(DeploymentOperation operation, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var items = await ReadUnsafeAsync(cancellationToken);
            var index = items.FindIndex(x => x.Id == operation.Id);
            if (index < 0) throw new InvalidOperationException("Deployment operation no longer exists.");
            items[index] = operation;
            await WriteUnsafeAsync(items, cancellationToken);
        }
        finally { _gate.Release(); }
    }

    private async Task<List<DeploymentOperation>> ReadUnsafeAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_filePath)) return [];
        await using var stream = File.OpenRead(_filePath);
        return await JsonSerializer.DeserializeAsync<List<DeploymentOperation>>(stream, _json, cancellationToken) ?? [];
    }

    private async Task WriteUnsafeAsync(List<DeploymentOperation> items, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_filePath)!);
        var temp = _filePath + ".tmp";
        await using (var stream = File.Create(temp)) await JsonSerializer.SerializeAsync(stream, items, _json, cancellationToken);
        File.Move(temp, _filePath, true);
    }
}

public sealed record DeploymentOperation(
    Guid Id,
    DateTimeOffset CreatedAtUtc,
    DateTimeOffset UpdatedAtUtc,
    string Status,
    string SubscriptionId,
    string HostPoolId,
    string HostPoolName,
    string HostPoolResourceGroup,
    string VmNamePrefix,
    int SessionHostCount,
    string VmSize,
    string GalleryImageVersion,
    bool ReplaceExisting,
    int GracePeriodHours,
    bool ForceLogoffAtDeadline,
    DateTimeOffset? GraceDeadlineUtc,
    int ActiveSessionCount,
    string? AutomationJobId,
    string? AutomationJobStatus,
    string? LastMessage,
    string? ErrorMessage,
    IReadOnlyList<DeploymentHostState>? OriginalHostStates = null);

public sealed record DeploymentHostState(string SessionHostName, bool AllowNewSession);
