using AVDManager.Web.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

public sealed class IndexModel : PageModel
{
    private readonly EnvironmentConfigurationStore _configurationStore;
    public IndexModel(EnvironmentConfigurationStore configurationStore) => _configurationStore = configurationStore;
    public EnvironmentConfiguration? EnvironmentConfiguration { get; private set; }

    public async Task<IActionResult> OnGetAsync(CancellationToken cancellationToken)
    {
        EnvironmentConfiguration = await _configurationStore.GetAsync(cancellationToken);
        if (EnvironmentConfiguration is null) return RedirectToPage("/Onboarding");
        return Page();
    }
}
