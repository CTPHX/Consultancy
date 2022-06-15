###########################################
Write-Host 'Creating Resource Group - Please Wait' -foregroundcolor red

$resourceGroupName = $versionNumber
$location = "UK South"
$parameters = @{
        ResourceGroup = $resourceGroupName
        Location = $location
}
New-AzResourceGroup @parameters


###########################################
Write-Host 'Creating AVD Hostpool - Please Wait' -foregroundcolor red

$hostpoolParameters = @{
    Name = $versionNumber
    Description = "Test Deployment for latest gold image"
    ResourceGroupName = $resourceGroupName
    Location = $location
    HostpoolType = "Pooled"
    LoadBalancerType = "BreadthFirst"
    preferredAppGroupType = "Desktop"
    ValidationEnvironment = $false
    StartVMOnConnect = $false
}
$avdHostpool = New-AzWvdHostPool @hostpoolParameters


###########################################
Write-Host 'Creating AVD Application Group - Please Wait' -foregroundcolor red

$applicationGroupParameters = @{
    ResourceGroupName = $ResourceGroupName
    Name = $versionNumber
    Location = $location
    FriendlyName = $versionNumber
    Description = "For testing"
    HostPoolArmPath =  $avdHostpool.Id
    ApplicationGroupType = "Desktop"
}
$applicationGroup = New-AzWvdApplicationGroup @applicationGroupParameters


###########################################
Write-Host 'Creating AVD Workspace - Please Wait' -foregroundcolor red

$workSpaceParameters = @{
    ResourceGroupName = $ResourceGroupName
    Name = "Party-Workspace"
    Location = $location
    FriendlyName = "The party workspace"
    ApplicationGroupReference = $applicationGroup.Id
    Description = "This is the place to party"
}
$workSpace = New-AzWvdWorkspace @workSpaceParameters


###########################################
Write-Host 'Creating Azure Keyvault - Please Wait' -foregroundcolor red

$keyVaultParameters = @{
    Name = "awkvtst-avdtt"
    ResourceGroupName = $resourceGroupName
    Location = $location
}
$keyVault = New-AzKeyVault @keyVaultParameters

$secretString = "Dell5100Dell5100"
$secretParameters = @{
    VaultName = $keyVault.VaultName
    Name= "vmjoinerPassword"
    SecretValue = ConvertTo-SecureString -String $secretString -AsPlainText -Force
}
$secret = Set-AzKeyVaultSecret @secretParameters


##########################################
Write-Host 'Creating Session Hosts - Please wait' -foregroundcolor red

$sessionHostCount = 1
$initialNumber = 1
$VMLocalAdminUser = "avdadmin"
$VMLocalAdminSecurePassword = ConvertTo-SecureString (Get-AzKeyVaultSecret -VaultName $keyVault.Vaultname -Name $secret.Name ) -AsPlainText -Force
$avdPrefix = "avd-"
$VMSize = "Standard_D2s_v3"
$DiskSizeGB = 512
$domainUser = "domainjoin@aidwright.co.uk"
$domain = $domainUser.Split("@")[-1]
$ouPath = "OU=WVD,DC=aidwright,DC=co,DC=uk"

$registrationToken = Update-AvdRegistrationToken -HostpoolName $avdHostpool.name $resourceGroupName
$moduleLocation = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration.zip"



Do {
    $VMName = $avdPrefix+"$initialNumber"
    $ComputerName = $VMName
    $nicName = "nic111-$vmName"
    $virtualNetwork = Get-AzVirtualNetwork -Name AWVNet -ResourceGroupName AW-DCs
    $NIC = New-AzNetworkInterface -Name $NICName -ResourceGroupName $ResourceGroupName -Location $location -SubnetId ($virtualNetwork.Subnets | Where { $_.Name -eq "Core" }).Id
    $Credential = New-Object System.Management.Automation.PSCredential ($VMLocalAdminUser, $VMLocalAdminSecurePassword);

    $VirtualMachine = New-AzVMConfig -VMName $VMName -VMSize $VMSize
    $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $ComputerName -Credential $Credential -ProvisionVMAgent -EnableAutoUpdate
    $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id
    $VirtualMachine = Set-AzVMOSDisk -Windows -VM $VirtualMachine -CreateOption FromImage -DiskSizeInGB $DiskSizeGB
    $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -Id $sourceImageVM.Id

    $sessionHost = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $VirtualMachine

    $initialNumber++
    $sessionHostCount--
    Write-Output "$VMName deployed"
}
while ($sessionHostCount -ne 0) {
    Write-Verbose "Session hosts are created"
}


##########################################
Write-Host 'Creating VM Extentsion - Please wait' -foregroundcolor red

  $domainJoinSettings = @{
        Name                   = "joindomain"
        Type                   = "JsonADDomainExtension" 
        Publisher              = "Microsoft.Compute"
        typeHandlerVersion     = "1.3"
        SettingString          = '{
            "name": "'+ $($domain) + '",
            "ouPath": "'+ $($ouPath) + '",
            "user": "'+ $($domainUser) + '",
            "restart": "'+ $true + '",
            "options": 3
        }'
        ProtectedSettingString = '{
            "password":"' + $(Get-AzKeyVaultSecret -VaultName $keyVault.Vaultname -Name $secret.Name -AsPlainText) + '"}'
        VMName                 = $VMName
        ResourceGroupName      = $resourceGroupName
        location               = $Location
    }
    Set-AzVMExtension @domainJoinSettings

    $avdDscSettings = @{
        Name               = "Microsoft.PowerShell.DSC"
        Type               = "DSC" 
        Publisher          = "Microsoft.Powershell"
        typeHandlerVersion = "2.73"
        SettingString      = "{
            ""modulesUrl"":'$avdModuleLocation',
            ""ConfigurationFunction"":""Configuration.ps1\\AddSessionHost"",
            ""Properties"": {
                ""hostPoolName"": ""$($fileParameters.avdSettings.avdHostpool.Name)"",
                ""registrationInfoToken"": ""$($registrationToken.token)"",
                ""aadJoin"": true
            }
        }"
        VMName             = $VMName
        ResourceGroupName  = $resourceGroupName
        location           = $Location
    }
    Set-AzVMExtension @avdDscSettings   


    ##########################################
Write-Host 'Deployment is complete - thank you' -foregroundcolor red