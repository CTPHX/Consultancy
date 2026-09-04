using System.Text.Json;

namespace AVDManager.Web.Services;

public sealed class EnvironmentConfigurationStore
{
    private readonly string _filePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly JsonSerializerOptions _jsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    public EnvironmentConfigurationStore(IWebHostEnvironment environment)
    {
        _filePath = Path.Combine(environment.ContentRootPath, "App_Data", "environment.json");
    }

    public async Task<EnvironmentConfiguration?> GetAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (!File.Exists(_filePath))
                return null;

            await using var stream = File.OpenRead(_filePath);
            return await JsonSerializer.DeserializeAsync<EnvironmentConfiguration>(stream, _jsonOptions, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SaveAsync(EnvironmentConfiguration configuration, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_filePath)!);
            var tempPath = _filePath + ".tmp";

            await using (var stream = File.Create(tempPath))
            {
                await JsonSerializer.SerializeAsync(stream, configuration, _jsonOptions, cancellationToken);
            }

            File.Move(tempPath, _filePath, overwrite: true);
        }
        finally
        {
            _gate.Release();
        }
    }
}

public sealed record EnvironmentConfiguration(
    string SubscriptionId,
    string SubscriptionName,
    DateTimeOffset SavedAtUtc,
    DateTimeOffset LastScannedAtUtc,
    IReadOnlyList<SavedHostPoolConfiguration> HostPools);

public sealed record SavedHostPoolConfiguration(
    string HostPoolId,
    string HostPoolName,
    string Location,
    SavedResourceGroupDefaults ResourceGroups,
    IReadOnlyList<string> ApplicationGroups,
    IReadOnlyList<SavedSessionHost> SessionHosts);

public sealed record SavedResourceGroupDefaults(
    string? Avd,
    string? SessionHosts,
    string? Network,
    string? Gallery,
    string? Storage,
    string? Automation,
    string? KeyVault);

public sealed record SavedSessionHost(
    string Name,
    string? Status,
    bool? AllowNewSession,
    int? Sessions,
    string? VmName,
    string? VmResourceGroup,
    string? NicName,
    string? VnetName,
    string? SubnetName,
    string? GalleryName,
    string? GalleryResourceGroup,
    string? ImageDefinition,
    string? ImageVersion);
