#To be uploaded to an automation account


# Define Variables
$subscriptionId = ""
$sourceResourceGroup = "rg-ukw-avd-images"
$targetResourceGroup = "rg-uks-avd-images"
$sourceGalleryName = "1"
$targetGalleryName = ""
$imageDefinitionName = ""
$locationTarget = "UK South"

try
{
    "Logging in to Azure..."
    Connect-AzAccount -Identity
}
catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}
#Set-AzContext -SubscriptionId $subscriptionId

# Get the latest image version from the source ACG
$latestImage = Get-AzGalleryImageVersion -ResourceGroupName $sourceResourceGroup `
                                         -GalleryName $sourceGalleryName `
                                         -GalleryImageDefinitionName $imageDefinitionName |
                Sort-Object -Property Name -Descending | Select-Object -First 1

if ($latestImage -eq $null) {
    Write-Host "No image versions found in the source gallery. Exiting."
    exit
}

$sourceImageVersion = $latestImage.Name
$sourceImageId = $latestImage.Id
Write-Host "Found latest image version: $sourceImageVersion"

# Check if the image version already exists in the target ACG
$existingTargetImage = Get-AzGalleryImageVersion -ResourceGroupName $targetResourceGroup `
                                                 -GalleryName $targetGalleryName `
                                                 -GalleryImageDefinitionName $imageDefinitionName `
                                                 -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -eq $sourceImageVersion }

if ($existingTargetImage) {
    Write-Host "Image version $sourceImageVersion already exists in $targetGalleryName. Skipping copy."
    exit
}

Write-Host "Replicating image version $sourceImageVersion to $targetGalleryName..."

# Create the Image Version in the Target ACG
New-AzGalleryImageVersion -ResourceGroupName $targetResourceGroup `
                          -GalleryName $targetGalleryName `
                          -GalleryImageDefinitionName $imageDefinitionName `
                          -Name $sourceImageVersion `
                          -Location $locationTarget `
                          -SourceImageId $sourceImageId

Write-Host "Image version $sourceImageVersion successfully replicated to $targetGalleryName in $locationTarget!"
