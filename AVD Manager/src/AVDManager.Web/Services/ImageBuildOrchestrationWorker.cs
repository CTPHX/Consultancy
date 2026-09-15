namespace AVDManager.Web.Services;

public sealed class ImageBuildOrchestrationWorker : BackgroundService
{
    private static readonly TimeSpan IdlePoll = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ActivePoll = TimeSpan.FromSeconds(10);
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ImageBuildOperationStore _store;
    private readonly ILogger<ImageBuildOrchestrationWorker> _logger;

    public ImageBuildOrchestrationWorker(IServiceScopeFactory scopeFactory, ImageBuildOperationStore store, ILogger<ImageBuildOrchestrationWorker> logger)
    { _scopeFactory = scopeFactory; _store = store; _logger = logger; }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("Image build orchestration worker started.");
        while (!stoppingToken.IsCancellationRequested)
        {
            var active = false;
            try { active = await ProcessAsync(stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception ex) { _logger.LogError(ex, "Image build orchestration worker iteration failed."); }
            try { await Task.Delay(active ? ActivePoll : IdlePoll, stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
        }
    }

    private async Task<bool> ProcessAsync(CancellationToken cancellationToken)
    {
        var operations = await _store.ListAsync(cancellationToken);
        var active = operations.Where(x => !IsTerminal(x.Status)).ToList();
        foreach (var operation in active)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var automation = scope.ServiceProvider.GetRequiredService<AzureAutomationService>();
                var environments = scope.ServiceProvider.GetRequiredService<EnvironmentConfigurationStore>();
                var environment = await environments.GetAsync(cancellationToken) ?? throw new InvalidOperationException("Environment configuration is unavailable.");
                var config = environment.Automation ?? throw new InvalidOperationException("Azure Automation has not been configured in Settings.");

                if (string.IsNullOrWhiteSpace(operation.AutomationJobId))
                {
                    var validation = await automation.ValidatePublishedRunbookAsync(operation.SubscriptionId, config.ResourceGroupName, config.AutomationAccountName, "BuildAVDImage", cancellationToken);
                    if (!validation.IsPublished) throw new InvalidOperationException("Runbook 'BuildAVDImage' is not published in the configured Automation Account.");

                    var parameters = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase)
                    {
                        ["SubscriptionId"] = operation.SubscriptionId,
                        ["Location"] = operation.Location,
                        ["GoldVmResourceGroupName"] = operation.GoldVmResourceGroup,
                        ["GoldVmName"] = operation.GoldVmName,
                        ["GalleryResourceGroupName"] = operation.GalleryResourceGroup,
                        ["GalleryName"] = operation.GalleryName,
                        ["GalleryImageDefinitionName"] = GetImageDefinitionName(operation.DefinitionId, operation.GalleryName, operation.DefinitionName),
                        ["GalleryImageVersion"] = operation.ImageVersion,
                        ["NetworkResourceGroupName"] = operation.NetworkResourceGroup,
                        ["VirtualNetworkName"] = operation.VirtualNetworkName,
                        ["SubnetName"] = operation.SubnetName,
                        ["VirtualMachineSize"] = operation.TempVmSize,
                        ["ReplicaCount"] = operation.ReplicaCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
                        ["TargetRegionsCsv"] = string.Join(",", operation.TargetRegions),
                        ["ExcludeFromLatest"] = operation.ExcludeFromLatest ? "1" : "0"
                    };
                    var submission = await automation.SubmitRunbookJobAsync(operation.SubscriptionId, config.ResourceGroupName, config.AutomationAccountName, "BuildAVDImage", parameters, cancellationToken);
                    await _store.UpdateAsync(operation with { UpdatedAtUtc=DateTimeOffset.UtcNow, Status="Submitted", AutomationJobId=submission.JobId, AutomationJobStatus=submission.Status, AutomationSubmittedAtUtc=DateTimeOffset.UtcNow, LastMessage=$"Azure Automation image-build job {submission.JobId} submitted.", ErrorMessage=null, AutomationOutput=[] }, cancellationToken);
                    continue;
                }

                var job = await automation.GetJobAsync(operation.SubscriptionId, config.ResourceGroupName, config.AutomationAccountName, operation.AutomationJobId, cancellationToken);
                IReadOnlyList<DeploymentAutomationOutputLine> output = operation.AutomationOutput ?? [];
                try
                {
                    output = (await automation.GetJobOutputAsync(operation.SubscriptionId, config.ResourceGroupName, config.AutomationAccountName, operation.AutomationJobId, cancellationToken))
                        .Select(x => new DeploymentAutomationOutputLine(x.StreamId, x.TimeUtc, x.Text)).ToList();
                }
                catch (Exception ex) { _logger.LogWarning(ex, "Could not refresh output for image build {OperationId}.", operation.Id); }

                var terminal = job.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase) || job.Status.Equals("Failed", StringComparison.OrdinalIgnoreCase) || job.Status.Equals("Stopped", StringComparison.OrdinalIgnoreCase) || job.Status.Equals("Suspended", StringComparison.OrdinalIgnoreCase);
                var status = job.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase) ? "Completed" : terminal ? "Failed" : job.Status;
                await _store.UpdateAsync(operation with { UpdatedAtUtc=DateTimeOffset.UtcNow, Status=status, AutomationJobStatus=job.Status, LastMessage=status=="Completed" ? $"Image {operation.DefinitionName} {operation.ImageVersion} built successfully." : $"Azure Automation image-build job is {job.Status}.", ErrorMessage=terminal && status!="Completed" ? (job.StatusDetails ?? job.Exception ?? $"Job ended with status {job.Status}.") : null, AutomationOutput=output }, cancellationToken);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Image build operation {OperationId} failed.", operation.Id);
                await _store.UpdateAsync(operation with { UpdatedAtUtc=DateTimeOffset.UtcNow, Status="Failed", LastMessage="The image-build workflow stopped.", ErrorMessage=ex.Message }, cancellationToken);
            }
        }
        return active.Count > 0;
    }

    private static string GetImageDefinitionName(string definitionId, string galleryName, string definitionName)
    {
        // Discovery normally stores the leaf image-definition name, but older/persisted
        // operations may contain a gallery-qualified display value. The ARM resource ID
        // is authoritative: .../galleries/{gallery}/images/{definition}.
        var parts = definitionId.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length - 1; i++)
        {
            if (parts[i].Equals("images", StringComparison.OrdinalIgnoreCase))
                return Uri.UnescapeDataString(parts[i + 1]);
        }

        var name = definitionName.Trim();
        var slash = name.LastIndexOf('/');
        if (slash >= 0 && slash < name.Length - 1)
            name = name[(slash + 1)..];

        if (string.IsNullOrWhiteSpace(name) || name.Equals(galleryName, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Could not resolve the gallery image definition name from resource ID '{definitionId}'.");

        return name;
    }

    private static bool IsTerminal(string status) => status.Equals("Completed", StringComparison.OrdinalIgnoreCase) || status.Equals("Failed", StringComparison.OrdinalIgnoreCase) || status.Equals("Cancelled", StringComparison.OrdinalIgnoreCase);
}
