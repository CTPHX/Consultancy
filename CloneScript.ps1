################################################################################################################
#Variables
################################################################################################################

#Location
$Location = 'UK South'

#Provide the Tenant Id
$tenantId = ''

#Provide the subscription Id
$subscriptionId = ''

#Resource Group for Gold Image
$ImagesRG = ""

#Resource Group for virtual Machine Networking
$NetworkRG = ""

#Provide the size of the virtual machine
$virtualMachineSize = 'Standard_D2ds_v5'

#Provide the name of an existing virtual network where virtual machine will be created
$virtualNetworkName = ''

#Provide temporary resource group for disposable resources
$TempRG = "AVD-Clone-" + (get-date -Format FileDateTime)

####################################################################################################################

#authenticate to azure

Connect-AzAccount -Tenant $tenantId -Subscription $subscriptionId

####################################################################################################################

#Generate version number from Azure Compure Gallery

$ErrorActionPreference = "Stop"

$galleryImageDefinitionName = Get-AzResource -ResourceType Microsoft.Compute/galleries/images| Out-GridView -OutputMode Single -Title 'Select the Image Definition'
$galleryImageDefinitionName = $galleryImageDefinitionName.Name.split("/")[1]

$imageVersions = Get-AzResource -ResourceType Microsoft.Compute/galleries/images/versions | where-object{$_.Name -Like "*$galleryImageDefinitionName*"} | select-object -last 1
 
  if ($imageVersions -eq $null){
     $versionNumber = "0.0.1"
     }
 else {
     
     $CurrentVersionNumber = $imageVersions.Name.split("/")
     $versionNumberarray = $CurrentVersionNumber[2]
     $versionobject = [version] $versionNumberarray
     $versionincrement = [version]::New($versionobject.Major,$versionobject.Minor,$versionobject.Build+1)
     $versionnumber = "$versionincrement"
         }
  if ($versionnumber.EndsWith(10)){
      $versionincrement = [version]::New($versionobject.Major+1,$versionobject.Minor,$versionobject.Build-9)
      $versionnumber = "$versionincrement"
      
      }

####################################################################################################################

#Prompt the user to select which Gold Image to be cloned

#Master Image Name
$gold = get-azvm -ResourceGroupName $ImagesRG | Out-GridView -OutputMode Single -Title 'Select the Gold Image you would like to clone'

if($gold -eq $null){

Exit}

####################################################################################################################

#Prompt the user to select the Network Subnet to be used
$vnet = Get-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $NetworkRG | Get-AzVirtualNetworkSubnetConfig | Select-Object -Property Name, Id | Out-GridView -OutputMode Single -Title 'Select the Network Subnet to be used'

####################################################################################################################

#Create temporary resource group

New-AzResourceGroup -Name $TempRG -Location $Location

#Clone Gold Image to a new VM (e.g. Gold-VM-V4)

$masterImage = $gold.name

#VM name for Snapshot
$VMName = $masterImage

#Provide the name of the snapshot that will be used to create OS disk
$snapshotName = ($masterImage + "-SNAPSHOT-" + "V" + $versionNumber)

#Provide the name of the OS disk that will be created using the snapshot
$osDiskName = ($masterImage + "-DISK-" + "V" + $versionNumber)

#Provide the name of the virtual machine
$virtualMachineName = ($masterImage + "-VM-" + "V" + $versionNumber)

$VMOSDisk=(Get-AZVM -ResourceGroupName $ImagesRG -Name $VMName).StorageProfile.OsDisk.Name
$Disk = Get-AzDisk -ResourceGroupName $ImagesRG -DiskName $VMOSDisk
$SnapshotConfig =  New-AzSnapshotConfig -SourceUri $Disk.Id -CreateOption Copy -Location $Location
$Snapshot=New-AzSnapshot -Snapshot $SnapshotConfig -SnapshotName $SnapshotName -ResourceGroupName $TempRG

#Set the context to the subscription Id where Managed Disk will be created
Select-AzSubscription -SubscriptionId $SubscriptionId

$snapshot = Get-AzSnapshot -ResourceGroupName $TempRG -SnapshotName $snapshotName

$diskConfig = New-AzDiskConfig -Location $snapshot.Location -SourceResourceId $snapshot.Id -CreateOption Copy

$disk = New-AzDisk -Disk $diskConfig -ResourceGroupName $TempRG -DiskName $osDiskName

#Initialize virtual machine configuration
$VirtualMachine = New-AzVMConfig -VMName $virtualMachineName -VMSize $virtualMachineSize

#disable boot diagnostics
$VirtualMachine | Set-AzVMBootDiagnostic -disable

#Use the Managed Disk Resource Id to attach it to the virtual machine. Please change the OS type to linux if OS disk has linux OS
$VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -ManagedDiskId $disk.Id -CreateOption Attach -Windows

#Create a public IP for the VM
#$publicIp = New-AzPublicIpAddress -Name ($VirtualMachineName.ToLower()+'_ip') -ResourceGroupName $resourceGroupName -Location $snapshot.Location -AllocationMethod Dynamic

#Get the virtual network where virtual machine will be hosted
#$vnet = Get-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $NetworkRG

# Create NIC in the first subnet of the virtual network
$nic = New-AzNetworkInterface -Name ($VirtualMachineName.ToLower()+'_nic') -ResourceGroupName $TempRG -Location $snapshot.Location -SubnetId $vnet.Id #-PublicIpAddressId $publicIp.Id

$VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $nic.Id

#Create the virtual machine with Managed Disk
New-AzVM -VM $VirtualMachine -ResourceGroupName $TempRG -Location $snapshot.Location -DisableBginfoExtension

####################################################################################################################

#Sysprep the cloned gold image and generalize ready for deployment to the Azure Compute Gallery

$content = 
@"
    param (
        `$sysprep,
        `$arg
    )
    Start-Process -FilePath `$sysprep -ArgumentList `$arg -Wait
"@

Set-Content -Path .\sysprep.ps1 -Value $content

$vm = Get-AzVM -Name $virtualMachineName
$vm | Invoke-AzVMRunCommand -CommandId "RunPowerShellScript" -ScriptPath .\sysprep.ps1 -Parameter @{sysprep = "C:\Windows\System32\Sysprep\Sysprep.exe";arg = "/generalize /oobe /mode:vm /quit"}

Stop-AzVM -Name $virtualMachineName -ResourceGroupName $TempRG -force

$vm | Set-AzVm -Generalized

####################################################################################################################

#Create an Azure Cumpute Gallery image from to cloned gold image

$galleries = Get-AzResource -ResourceType Microsoft.Compute/galleries
$galleriesRG=$galleries.ResourceGroupName
$galleryName=$galleries.Name
$galleryImageVersionName = $versionNumber
$sourceImageVM=get-azvm -ResourceGroupName $TempRG -Name $virtualMachineName
$sourceImageId=$sourceImageVM.Id
New-AzGalleryImageVersion -ResourceGroupName $galleriesRG -GalleryName $galleryName -GalleryImageDefinitionName $galleryImageDefinitionName -Name $galleryImageVersionName -Location $location -SourceImageId $sourceImageId

#######################################################################################################################

#Cleanup

Remove-AzResourceGroup -Name $TempRG -Force
