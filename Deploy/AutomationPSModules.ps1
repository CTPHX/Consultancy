Set-AzContext -SubscriptionId "X-X-X-X"


$modules = @{
    "Az.Accounts"              = "https://www.powershellgallery.com/api/v2/package/Az.Accounts/5.3.1"
    "Az.Resources"             = "https://www.powershellgallery.com/api/v2/package/Az.Resources/9.0.0"
    "Az.Network"               = "https://www.powershellgallery.com/api/v2/package/Az.Network/7.24.0"
    "Az.Compute"               = "https://www.powershellgallery.com/api/v2/package/Az.Compute/11.1.0"
    "Az.DesktopVirtualization" = "https://www.powershellgallery.com/api/v2/package/Az.DesktopVirtualization/5.4.1"
}

foreach ($module in $modules.GetEnumerator()) {
    New-AzAutomationModule `
        -ResourceGroupName "<RG Name>" `
        -AutomationAccountName "<AA Name>" `
        -Name $module.Key `
        -ContentLinkUri $module.Value
}
