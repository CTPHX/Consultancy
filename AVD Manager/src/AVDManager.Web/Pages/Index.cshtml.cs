using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AVDManager.Web.Pages;

public sealed class IndexModel : PageModel
{
    public IActionResult OnGet()
    {
        // Until an environment has been successfully discovered and persisted,
        // the root of AVD Manager is the first-time setup experience.
        // This will later be replaced with a persisted EnvironmentConfigured check.
        return RedirectToPage("/Onboarding");
    }
}
