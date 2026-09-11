namespace AVDManager.Web.Services;

public sealed class DeploymentOrchestrationWorker : BackgroundService
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(30);

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
            try
            {
                await ProcessOperationsAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Deployment orchestration worker iteration failed.");
            }

            try
            {
                await Task.Delay(PollInterval, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }
    }

    private async Task ProcessOperationsAsync(CancellationToken cancellationToken)
    {
        var operations = await _operationStore.ListAsync(cancellationToken);
        var active = operations
            .Where(operation =>
                operation.Status.Equals("Starting", StringComparison.OrdinalIgnoreCase) ||
                operation.Status.Equals("Draining", StringComparison.OrdinalIgnoreCase) ||
                operation.Status.Equals("WaitingForSessions", StringComparison.OrdinalIgnoreCase))
            .ToList();

        foreach (var operation in active)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();
                var sessionHosts = scope.ServiceProvider.GetRequiredService<AvdSessionHostOperationsService>();
                var userSessions = scope.ServiceProvider.GetRequiredService<AvdUserSessionService>();

                if (!operation.ReplaceExisting)
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

                if (operation.Status.Equals("Starting", StringComparison.OrdinalIgnoreCase) ||
                    operation.Status.Equals("Draining", StringComparison.OrdinalIgnoreCase))
                {
                    foreach (var host in operation.OriginalHostStates ?? [])
                    {
                        await sessionHosts.SetAllowNewSessionAsync(
                            operation.SubscriptionId,
                            operation.HostPoolResourceGroup,
                            operation.HostPoolName,
                            host.SessionHostName,
                            false,
                            cancellationToken);
                    }
                }

                var sessions = await userSessions.ListByHostPoolAsync(
                    operation.SubscriptionId,
                    operation.HostPoolResourceGroup,
                    operation.HostPoolName,
                    cancellationToken);

                if (sessions.Count == 0)
                {
                    await _operationStore.UpdateAsync(operation with
                    {
                        UpdatedAtUtc = DateTimeOffset.UtcNow,
                        ActiveSessionCount = 0,
                        Status = "ReadyForAutomation",
                        LastMessage = "No user sessions remain. The operation is ready for the next Automation stage.",
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
                        try
                        {
                            await userSessions.LogoffAsync(session.ResourceId, cancellationToken);
                        }
                        catch (Exception ex)
                        {
                            logoffFailures.Add($"{session.UserPrincipalName}: {ex.Message}");
                        }
                    }

                    if (logoffFailures.Count > 0)
                    {
                        await _operationStore.UpdateAsync(operation with
                        {
                            UpdatedAtUtc = DateTimeOffset.UtcNow,
                            ActiveSessionCount = sessions.Count,
                            Status = "WaitingForSessions",
                            LastMessage = "The grace period has expired. AVD Manager attempted forced logoff but one or more sessions could not be logged off.",
                            ErrorMessage = string.Join(" | ", logoffFailures)
                        }, cancellationToken);
                        continue;
                    }

                    await _operationStore.UpdateAsync(operation with
                    {
                        UpdatedAtUtc = DateTimeOffset.UtcNow,
                        ActiveSessionCount = sessions.Count,
                        Status = "WaitingForSessions",
                        LastMessage = $"The grace period has expired. Forced logoff was requested for {sessions.Count} remaining session(s); waiting for Azure to confirm they have cleared.",
                        ErrorMessage = null
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
                        LastMessage = "AVD Manager could not reconcile this deployment operation. It will retry automatically."
                    }, cancellationToken);
                }
                catch (Exception updateException)
                {
                    _logger.LogError(updateException, "Could not persist reconciliation failure for deployment operation {OperationId}.", operation.Id);
                }
            }
        }
    }
}
