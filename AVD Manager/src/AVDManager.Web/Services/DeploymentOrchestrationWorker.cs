namespace AVDManager.Web.Services;

public sealed class DeploymentOrchestrationWorker : BackgroundService
{
    private static readonly TimeSpan IdlePollInterval = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ActiveAutomationPollInterval = TimeSpan.FromSeconds(10);
    private static readonly string[] AutomationActiveStatuses = ["Submitted", "New", "Activating", "Queued", "Running", "Resuming", "Stopping"];

    private readonly IServiceScopeFactory _scopeFactory;
    private readonly DeploymentOperationStore _operationStore;
    private readonly ILogger<DeploymentOrchestrationWorker> _logger;

    public DeploymentOrchestrationWorker(
        IServiceScopeFactory scopeFactory,
        DeploymentOperationStore operationStore,
        ILogger<DeploymentOrchestrationWorker> logger)
    {
        _scopeFactory = scopeFactory;
        _operationStore = operationStore;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("Deployment orchestration worker started.");

        while (!stoppingToken.IsCancellationRequested)
        {
            try { await ProcessOperationsAsync(stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception ex) { _logger.LogError(ex, "Deployment orchestration worker iteration failed."); }

            var delay = await HasActiveAutomationJobsAsync(stoppingToken) ? ActiveAutomationPollInterval : IdlePollInterval;
            try { await Task.Delay(delay, stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
        }
    }

    private async Task<bool> HasActiveAutomationJobsAsync(CancellationToken cancellationToken)
    {
        var operations = await _operationStore.ListAsync(cancellationToken);
        return operations.Any(operation => !string.IsNullOrWhiteSpace(operation.AutomationJobId) &&
            AutomationActiveStatuses.Contains(operation.Status, StringComparer.OrdinalIgnoreCase));
    }

    private async Task ProcessOperationsAsync(CancellationToken cancellationToken)
    {
        var operations = await _operationStore.ListAsync(cancellationToken);
        var active = operations.Where(operation =>
            operation.Status.Equals("Starting", StringComparison.OrdinalIgnoreCase) ||
            operation.Status.Equals("Draining", StringComparison.OrdinalIgnoreCase) ||
            operation.Status.Equals("WaitingForSessions", StringComparison.OrdinalIgnoreCase) ||
            operation.Status.Equals("ReadyForAutomation", StringComparison.OrdinalIgnoreCase) ||
            AutomationActiveStatuses.Contains(operation.Status, StringComparer.OrdinalIgnoreCase)).ToList();

        foreach (var operation in active)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var sessionHosts = scope.ServiceProvider.GetRequiredService<AvdSessionHostOperationsService>();
                var userSessions = scope.ServiceProvider.GetRequiredService<AvdUserSessionService>();
                var automation = scope.ServiceProvider.GetRequiredService<AzureAutomationService>();
                var environmentStore = scope.ServiceProvider.GetRequiredService<EnvironmentConfigurationStore>();

                if (!string.IsNullOrWhiteSpace(operation.AutomationJobId))
                {
                    await ReconcileAutomationJobAsync(operation, automation, environmentStore, cancellationToken);
                    continue;
                }

                if (!operation.ReplaceExisting)
                {
                    if (!operation.Status.Equals("ReadyForAutomation", StringComparison.OrdinalIgnoreCase))
                    {
                        await _operationStore.UpdateAsync(operation with
                        {
                            UpdatedAtUtc = DateTimeOffset.UtcNow,
                            Status = "ReadyForAutomation",
                            LastMessage = "Deployment request is ready for Azure Automation submission.",
                            ErrorMessage = null
                        }, cancellationToken);
                        continue;
                    }

                    await SubmitAutomationJobAsync(operation, automation, environmentStore, cancellationToken);
                    continue;
                }

                if (operation.Status.Equals("ReadyForAutomation", StringComparison.OrdinalIgnoreCase))
                {
                    var preSubmitSessions = await userSessions.ListByHostPoolAsync(
                        operation.SubscriptionId, operation.HostPoolResourceGroup, operation.HostPoolName, cancellationToken);

                    if (preSubmitSessions.Count > 0)
                    {
                        await _operationStore.UpdateAsync(operation with
                        {
                            UpdatedAtUtc = DateTimeOffset.UtcNow,
                            ActiveSessionCount = preSubmitSessions.Count,
                            Status = "WaitingForSessions",
                            LastMessage = $"Pre-submit safety check detected {preSubmitSessions.Count} active user session(s). Azure Automation submission has been blocked and the operation has returned to waiting.",
                            ErrorMessage = null
                        }, cancellationToken);
                        continue;
                    }

                    await SubmitAutomationJobAsync(operation with { ActiveSessionCount = 0 }, automation, environmentStore, cancellationToken);
                    continue;
                }

                if (operation.Status.Equals("Starting", StringComparison.OrdinalIgnoreCase) ||
                    operation.Status.Equals("Draining", StringComparison.OrdinalIgnoreCase))
                {
                    foreach (var host in operation.OriginalHostStates ?? [])
                        await sessionHosts.SetAllowNewSessionAsync(
                            operation.SubscriptionId, operation.HostPoolResourceGroup, operation.HostPoolName,
                            host.SessionHostName, false, cancellationToken);
                }

                var sessions = await userSessions.ListByHostPoolAsync(
                    operation.SubscriptionId, operation.HostPoolResourceGroup, operation.HostPoolName, cancellationToken);

                if (sessions.Count == 0)
                {
                    await _operationStore.UpdateAsync(operation with
                    {
                        UpdatedAtUtc = DateTimeOffset.UtcNow,
                        ActiveSessionCount = 0,
                        Status = "ReadyForAutomation",
                        LastMessage = "No user sessions remain. The operation is ready for the final pre-submit safety check.",
                        ErrorMessage = null
                    }, cancellationToken);
                    continue;
                }

                var deadlineExpired = operation.GraceDeadlineUtc is not null &&
                                      DateTimeOffset.UtcNow >= operation.GraceDeadlineUtc.Value;

                if (deadlineExpired && operation.ForceLogoffAtDeadline)
                {
                    var logoffFailures = new List<string>();
                    foreach (var session in sessions)
                    {
                        try { await userSessions.LogoffAsync(session.ResourceId, cancellationToken); }
                        catch (Exception ex) { logoffFailures.Add($"{session.UserPrincipalName}: {ex.Message}"); }
                    }

                    await _operationStore.UpdateAsync(operation with
                    {
                        UpdatedAtUtc = DateTimeOffset.UtcNow,
                        ActiveSessionCount = sessions.Count,
                        Status = "WaitingForSessions",
                        LastMessage = logoffFailures.Count > 0
                            ? "The grace period has expired. AVD Manager attempted forced logoff but one or more sessions could not be logged off."
                            : $"The grace period has expired. Forced logoff was requested for {sessions.Count} remaining session(s); waiting for Azure to confirm they have cleared.",
                        ErrorMessage = logoffFailures.Count > 0 ? string.Join(" | ", logoffFailures) : null
                    }, cancellationToken);
                    continue;
                }

                var message = deadlineExpired
                    ? $"{sessions.Count} user session(s) remain. The grace period has expired and forced logoff is disabled, so AVD Manager will continue waiting for users to log off normally."
                    : $"{sessions.Count} user session(s) remain. Hosts are drained and the grace period is running.";

                await _operationStore.UpdateAsync(operation with
                {
                    UpdatedAtUtc = DateTimeOffset.UtcNow,
                    ActiveSessionCount = sessions.Count,
                    Status = "WaitingForSessions",
                    LastMessage = message,
                    ErrorMessage = null
                }, cancellationToken);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Could not process deployment operation {OperationId} for host pool {HostPoolName}.", operation.Id, operation.HostPoolName);
                try
                {
                    await _operationStore.UpdateAsync(operation with
                    {
                        UpdatedAtUtc = DateTimeOffset.UtcNow,
                        ErrorMessage = ex.Message,
                        LastMessage = string.IsNullOrWhiteSpace(operation.AutomationJobId)
                            ? "AVD Manager could not process this deployment operation. It will retry automatically."
                            : "AVD Manager could not refresh the Azure Automation job. It will retry automatically."
                    }, cancellationToken);
                }
                catch (Exception updateException)
                {
                    _logger.LogError(updateException, "Could not persist reconciliation failure for deployment operation {OperationId}.", operation.Id);
                }
            }
        }
    }

    private async Task SubmitAutomationJobAsync(
        DeploymentOperation operation,
        AzureAutomationService automation,
        EnvironmentConfigurationStore environmentStore,
        CancellationToken cancellationToken)
    {
        var environment = await environmentStore.GetAsync(cancellationToken)
            ?? throw new InvalidOperationException("Environment configuration is unavailable.");
        var automationConfig = environment.Automation
            ?? throw new InvalidOperationException("Azure Automation has not been configured in Settings.");

        var pool = environment.HostPools.FirstOrDefault(p => p.HostPoolId.Equals(operation.HostPoolId, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException($"Host pool '{operation.HostPoolName}' is no longer present in the saved environment.");
        var defaults = pool.DeploymentDefaults
            ?? throw new InvalidOperationException($"Advanced deployment defaults are not configured for '{operation.HostPoolName}'.");
        var shared = environment.DeploymentDefaults
            ?? throw new InvalidOperationException("Environment-wide Advanced deployment defaults are not configured.");

        var parameters = BuildRunbookParameters(operation, pool, defaults, shared);
        var submission = await automation.SubmitRunbookJobAsync(
            operation.SubscriptionId,
            automationConfig.ResourceGroupName,
            automationConfig.AutomationAccountName,
            automationConfig.DeploymentRunbookName,
            parameters,
            cancellationToken);

        await _operationStore.UpdateAsync(operation with
        {
            UpdatedAtUtc = DateTimeOffset.UtcNow,
            Status = "Submitted",
            AutomationJobId = submission.JobId,
            AutomationJobStatus = submission.Status,
            ActiveSessionCount = 0,
            LastMessage = $"Azure Automation job {submission.JobId} was submitted successfully.",
            ErrorMessage = null,
            AutomationOutput = []
        }, cancellationToken);
    }

    private async Task ReconcileAutomationJobAsync(
        DeploymentOperation operation,
        AzureAutomationService automation,
        EnvironmentConfigurationStore environmentStore,
        CancellationToken cancellationToken)
    {
        var environment = await environmentStore.GetAsync(cancellationToken)
            ?? throw new InvalidOperationException("Environment configuration is unavailable.");
        var config = environment.Automation
            ?? throw new InvalidOperationException("Azure Automation configuration is unavailable.");

        var job = await automation.GetJobAsync(
            operation.SubscriptionId, config.ResourceGroupName, config.AutomationAccountName,
            operation.AutomationJobId!, cancellationToken);
        var output = await automation.GetJobOutputAsync(
            operation.SubscriptionId, config.ResourceGroupName, config.AutomationAccountName,
            operation.AutomationJobId!, cancellationToken);

        var persistedOutput = output
            .Select(line => new DeploymentAutomationOutputLine(line.StreamId, line.TimeUtc, line.Text))
            .ToList();

        var terminal = job.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase) ||
                       job.Status.Equals("Failed", StringComparison.OrdinalIgnoreCase) ||
                       job.Status.Equals("Stopped", StringComparison.OrdinalIgnoreCase) ||
                       job.Status.Equals("Suspended", StringComparison.OrdinalIgnoreCase);

        var status = job.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase)
            ? "Completed"
            : terminal ? "Failed" : NormalizeActiveAutomationStatus(job.Status);

        var detail = !string.IsNullOrWhiteSpace(job.StatusDetails) ? job.StatusDetails : job.Exception;
        var message = status.Equals("Completed", StringComparison.OrdinalIgnoreCase)
            ? "Azure Automation deployment completed successfully."
            : terminal
                ? $"Azure Automation deployment ended with status '{job.Status}'."
                : $"Azure Automation job is {job.Status}.";

        await _operationStore.UpdateAsync(operation with
        {
            UpdatedAtUtc = DateTimeOffset.UtcNow,
            Status = status,
            AutomationJobStatus = job.Status,
            LastMessage = message,
            ErrorMessage = terminal && !job.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase) ? detail : null,
            AutomationOutput = persistedOutput
        }, cancellationToken);
    }

    private static string NormalizeActiveAutomationStatus(string status) =>
        status.Equals("New", StringComparison.OrdinalIgnoreCase) ||
        status.Equals("Activating", StringComparison.OrdinalIgnoreCase)
            ? "Submitted"
            : status;

    private static IReadOnlyDictionary<string, string> BuildRunbookParameters(
        DeploymentOperation operation,
        SavedHostPoolConfiguration pool,
        SavedHostPoolDeploymentDefaults defaults,
        SavedDeploymentEnvironmentDefaults shared)
    {
        return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["SubscriptionId"] = operation.SubscriptionId,
            ["Location"] = pool.Location,
            ["HostPoolName"] = operation.HostPoolName,
            ["HostPoolResourceGroupName"] = operation.HostPoolResourceGroup,
            ["SessionHostResourceGroupName"] = Required(defaults.SessionHostResourceGroupName, "Session host resource group"),
            ["VmNamePrefix"] = operation.VmNamePrefix,
            ["SessionHostCount"] = operation.SessionHostCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["OverwriteExisting"] = operation.ReplaceExisting.ToString(),
            ["VmSize"] = operation.VmSize,
            ["GalleryResourceGroupName"] = Required(defaults.GalleryResourceGroupName, "Gallery resource group"),
            ["GalleryName"] = Required(defaults.GalleryName, "Gallery name"),
            ["GalleryImageDefinitionName"] = Required(defaults.GalleryImageDefinitionName, "Gallery image definition"),
            ["GalleryImageVersion"] = operation.GalleryImageVersion,
            ["VirtualNetworkResourceGroupName"] = Required(defaults.VirtualNetworkResourceGroupName, "Virtual network resource group"),
            ["VirtualNetworkName"] = Required(defaults.VirtualNetworkName, "Virtual network"),
            ["SubnetName"] = Required(defaults.SubnetName, "Subnet"),
            ["KeyVaultName"] = Required(defaults.KeyVaultName, "Key Vault"),
            ["JoinType"] = defaults.JoinType,
            ["LocalAdminUsernameSecretName"] = shared.LocalAdminUsernameSecretName,
            ["LocalAdminPasswordSecretName"] = shared.LocalAdminPasswordSecretName,
            ["DomainFqdn"] = defaults.DomainFqdn ?? string.Empty,
            ["DomainOuPath"] = defaults.DomainOuPath ?? string.Empty,
            ["DomainJoinUsernameSecretName"] = shared.DomainJoinUsernameSecretName,
            ["DomainJoinPasswordSecretName"] = shared.DomainJoinPasswordSecretName,
            ["TenantId"] = shared.TenantId ?? string.Empty,
            ["EnableIntuneEnrollment"] = shared.EnableIntuneEnrollment.ToString(),
            ["IntuneMdmId"] = shared.IntuneMdmId ?? string.Empty,
            ["InstallRdsRoleOnServerOS"] = defaults.InstallRdsRoleOnServerOs.ToString(),
            ["TemporarilyDisableScalingDuringDeployment"] = defaults.TemporarilyDisableScalingDuringDeployment.ToString(),
            ["EnvironmentTag"] = shared.EnvironmentTagValue
        };
    }

    private static string Required(string? value, string label) =>
        !string.IsNullOrWhiteSpace(value) ? value : throw new InvalidOperationException($"{label} is not configured.");
}
