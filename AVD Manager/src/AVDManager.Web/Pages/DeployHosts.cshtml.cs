using AVDManager.Web.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using System.Text.RegularExpressions;

namespace AVDManager.Web.Pages;

[Authorize]
public sealed class DeployHostsModel : PageModel
{
    private readonly EnvironmentConfigurationStore _environmentStore;

    public DeployHostsModel(EnvironmentConfigurationStore environmentStore)
    {
        _environmentStore = environmentStore;
    }

    public EnvironmentConfiguration? EnvironmentConfiguration { get; private set; }
    public IReadOnlyList<DeployHostPoolOption> HostPools { get; private set; } = [];

    public async Task<IActionResult> OnGetAsync(CancellationToken cancellationToken)
    {
        var environment = await _environmentStore.GetAsync(cancellationToken);
        if (environment is null)
            return RedirectToPage("/Onboarding");

        EnvironmentConfiguration = environment;
        HostPools = environment.HostPools
            .OrderBy(pool => pool.HostPoolName, StringComparer.OrdinalIgnoreCase)
            .Select(BuildHostPoolOption)
            .ToList();

        return Page();
    }

    private static DeployHostPoolOption BuildHostPoolOption(SavedHostPoolConfiguration pool)
    {
        var mappedHost = pool.SessionHosts
            .OrderByDescending(host => !string.IsNullOrWhiteSpace(host.ImageVersion))
            .ThenBy(host => host.Name, StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault();

        var suggestedPrefix = SuggestVmPrefix(mappedHost?.VmName);

        return new DeployHostPoolOption(
            pool.HostPoolId,
            pool.HostPoolName,
            pool.Location,
            pool.SessionHosts.Count,
            suggestedPrefix,
            pool.ResourceGroups.Avd,
            pool.ResourceGroups.SessionHosts,
            pool.ResourceGroups.Network,
            pool.ResourceGroups.Gallery,
            pool.ResourceGroups.Automation,
            mappedHost?.VnetName,
            mappedHost?.SubnetName,
            mappedHost?.GalleryName,
            mappedHost?.ImageDefinition,
            mappedHost?.ImageVersion);
    }

    private static string SuggestVmPrefix(string? vmName)
    {
        if (string.IsNullOrWhiteSpace(vmName))
            return string.Empty;

        var withoutNumber = Regex.Replace(vmName, @"\d+$", string.Empty).TrimEnd('-', '_');
        return string.IsNullOrWhiteSpace(withoutNumber) ? vmName : withoutNumber;
    }
}

public sealed record DeployHostPoolOption(
    string HostPoolId,
    string HostPoolName,
    string Location,
    int ExistingHostCount,
    string SuggestedVmPrefix,
    string? AvdResourceGroup,
    string? SessionHostResourceGroup,
    string? NetworkResourceGroup,
    string? GalleryResourceGroup,
    string? AutomationResourceGroup,
    string? VnetName,
    string? SubnetName,
    string? GalleryName,
    string? ImageDefinition,
    string? ImageVersion);
