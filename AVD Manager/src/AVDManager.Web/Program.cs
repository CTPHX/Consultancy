using Azure.Core;
using Azure.Identity;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Identity.Web;
using Microsoft.Identity.Web.UI;

var builder = WebApplication.CreateBuilder(args);

builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor |
                               ForwardedHeaders.XForwardedProto |
                               ForwardedHeaders.XForwardedHost;
    options.KnownNetworks.Clear();
    options.KnownProxies.Clear();
});

builder.Services
    .AddAuthentication(OpenIdConnectDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApp(builder.Configuration.GetSection("AzureAd"));

builder.Services.AddAuthorization();
builder.Services.AddRazorPages().AddMicrosoftIdentityUI();
builder.Services.AddHttpContextAccessor();
builder.Services.AddHttpClient();

builder.Services.AddSingleton<TokenCredential>(sp =>
{
    var configuration = sp.GetRequiredService<IConfiguration>();
    var tenantId = configuration["AzureAd:TenantId"];
    var clientId = configuration["AzureAd:ClientId"];
    var clientSecret = configuration["AzureAd:ClientSecret"];

    if (string.IsNullOrWhiteSpace(tenantId) || string.IsNullOrWhiteSpace(clientId))
        throw new InvalidOperationException("AzureAd TenantId and ClientId must be configured.");

    if (!string.IsNullOrWhiteSpace(clientSecret))
        return new ClientSecretCredential(tenantId, clientId, clientSecret);

    return new DefaultAzureCredential(new DefaultAzureCredentialOptions
    {
        TenantId = tenantId,
        ManagedIdentityClientId = clientId
    });
});

builder.Services.AddScoped<AVDManager.Web.Services.AzureDiscoveryService>();
builder.Services.AddScoped<AVDManager.Web.Services.AzureVmImageDiscoveryService>();
builder.Services.AddSingleton<AVDManager.Web.Services.EnvironmentConfigurationStore>();

var app = builder.Build();
app.UseForwardedHeaders();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();
app.UseAuthentication();
app.UseAuthorization();
app.MapRazorPages();
app.MapControllers();
app.Run();
