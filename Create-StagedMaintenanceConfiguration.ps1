<#
.SYNOPSIS
    Runbook that automatically creates one or more maintenance configurations in Azure Update Manager, based on update packages already installed on an initial environment (Pre/Dev/Test/QA).

.DESCRIPTION 
    This Runbook uses Azure Update Manager installation results to query the latest update packages installed on a set of machines, and based on a maintenance configuration already deployed, 
    and creates one or more maintenance configurations based on the next stages definitions set as a parameter.

    These parameters are needed:
        .PARAMETER MaintenanceConfigurationId
            ARM Id of the Maintenance Configuration to be used as a reference to create maintenance configurations for further stages
        .PARAMETER NextStagePropertiesJson
            JSON-formatted parameter that will define the scope of the new maintenance configurations. See https://github.com/helderpinto/AzureUpdateManagerTools for more details.
.NOTES
    AUTHOR: Helder Pinto and Wiszanyel Cruz
#>

param(
    [parameter(Mandatory = $true)]
    [string]$MaintenanceConfigurationId,

    [parameter(Mandatory = $true)]
    [string]$NextStagePropertiesJson 
)

$ErrorActionPreference = "Stop"

$NextStageProperties = $NextStagePropertiesJson | ConvertFrom-Json

Connect-AzAccount -Identity

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } | ForEach-Object { "$($_.Id)"}

Write-Output "Getting the latest maintenance configuration execution run..."

$argQuery = @"
patchinstallationresources
| where type endswith '/patchinstallationresults'
| extend maintenanceRunId=tolower(split(properties.maintenanceRunId,'/providers/microsoft.maintenance/applyupdates')[0])
| where maintenanceRunId =~ '$MaintenanceConfigurationId'
| top 1 by todatetime(properties.lastModifiedDateTime)
| project lastRunDateTime = datetime_add('Hour',-12,todatetime(properties.lastModifiedDateTime))
"@

$lastRunDateTime = Search-AzGraph -Query $argQuery -Subscription $subscriptions

if ($lastRunDateTime.Data -and $lastRunDateTime.GetType().Name -like "PSResourceGraphResponse*")
{
    $lastRunDateTime = $lastRunDateTime.Data
}

if ($lastRunDateTime[0])
{
    Write-Output "Latest run for maintenance configuration $MaintenanceConfigurationId ended at $($lastRunDateTime[0].lastRunDateTime.AddHours(12).ToString("u"))"
}
else
{
    throw "No maintenance configuration runs found for $MaintenanceConfigurationId"
}

$ARGPageSize = 1000

$installedPackages = @()

$resultsSoFar = 0

Write-Output "Querying for packages to install..."

$argQuery = @"
patchinstallationresources
| where type endswith '/patchinstallationresults'
| extend maintenanceRunId=tolower(split(properties.maintenanceRunId,'/providers/microsoft.maintenance/applyupdates')[0])
| where maintenanceRunId =~ '$MaintenanceConfigurationId'
| where todatetime(properties.lastModifiedDateTime) > todatetime('$($lastRunDateTime[0].lastRunDateTime.ToString("u"))')
| extend vmId = tostring(split(tolower(id), '/patchinstallationresults/')[0])
| extend osType = tostring(properties.osType)
| extend lastDeploymentStart = tostring(properties.startDateTime)
| extend deploymentStatus = tostring(properties.status)
| join kind=inner (
    patchinstallationresources
    | where type endswith '/patchinstallationresults/softwarepatches'
    | where todatetime(properties.lastModifiedDateTime) > todatetime('$($lastRunDateTime[0].lastRunDateTime.ToString("u"))')
    | extend vmId = tostring(split(tolower(id), '/patchinstallationresults/')[0])
    | extend patchName = tostring(properties.patchName)
    | extend patchVersion = tostring(properties.version)
    | extend kbId = tostring(properties.kbId)
    | extend installationState = tostring(properties.installationState)
    | project vmId, installationState, patchName, patchVersion, kbId
) on vmId
| join kind=inner ( 
    resources
    | where type == 'microsoft.maintenance/maintenanceconfigurations'
    | extend maintenanceDuration = tostring(properties.maintenanceWindow.duration)
    | extend rebootSetting = tostring(properties.installPatches.rebootSetting)
    | project maintenanceRunId=tolower(id), maintenanceDuration, rebootSetting, location, mcTags=tostring(tags)
) on maintenanceRunId
| where installationState == 'Installed'
| distinct osType, lastDeploymentStart, maintenanceDuration, patchName, patchVersion, kbId, rebootSetting, location, mcTags
"@

do
{
    if ($resultsSoFar -eq 0)
    {
        $packages = Search-AzGraph -Query $argQuery -First $ARGPageSize -Subscription $subscriptions
    }
    else
    {
        $packages = Search-AzGraph -Query $argQuery -First $ARGPageSize -Skip $resultsSoFar -Subscription $subscriptions
    }
    if ($packages -and $packages.GetType().Name -eq "PSResourceGraphResponse")
    {
        $packages = $packages.Data
    }
    $resultsCount = $packages.Count
    $resultsSoFar += $resultsCount
    $installedPackages += $packages

} while ($resultsCount -eq $ARGPageSize)

Write-Output "$($installedPackages.Count) packages were installed in the latest run for maintenance configuration $MaintenanceConfigurationId."

if ($installedPackages.Count -gt 0) 
{
    $lastDeploymentDate = ($installedPackages | Select-Object -Property lastDeploymentStart -Unique -First 1).lastDeploymentStart
    $maintenanceConfLocation = ($installedPackages | Select-Object -Property location -Unique -First 1).location
    $maintenanceDuration = ($installedPackages | Select-Object -Property maintenanceDuration -Unique -First 1).maintenanceDuration
    $rebootSetting = ($installedPackages | Select-Object -Property rebootSetting -Unique -First 1).rebootSetting
    $tags = ($installedPackages | Select-Object -Property mcTags -Unique -First 1).mcTags
    $windowsPackages = ($installedPackages | Where-Object { $_.osType -eq "Windows" } | Select-Object -Property kbId -Unique).kbId
    $windowsPackageNames = ($installedPackages | Where-Object { $_.osType -eq "Windows" } | Select-Object -Property patchName -Unique).patchName
    $kbNumbersToInclude = "[ ]"
    if ($windowsPackages)
    {
        if ($windowsPackages.Count -eq 1)
        {
            $kbNumbersToInclude = '[ "' + $windowsPackages + '" ]'
        }
        else
        {
            $kbNumbersToInclude = $windowsPackages | ConvertTo-Json
        }
    }
    $linuxPatches = ($installedPackages | Where-Object { $_.osType -eq "Linux" } | Select-Object -Property patchName -Unique).patchName
    $packageNameMasksToInclude = "[ ]"
    $linuxPackages = @()
    foreach ($linuxPatch in $linuxPatches) 
    {
        $linuxPatchVersion = ($installedPackages | Where-Object { $_.osType -eq "Linux" -and $_.patchName -eq $linuxPatch } | Select-Object -Property patchVersion -Unique | Sort-Object -Property patchVersion -Descending | Select-Object -First 1).patchVersion
        $linuxPackage = "$linuxPatch=$linuxPatchVersion"
        $linuxPackages += $linuxPackage
    }
    if ($linuxPackages.Count -eq 1)
    {
        $packageNameMasksToInclude = '[ "' + $linuxPackages + '" ]'
    }
    else
    {
        if ($linuxPackages.Count -gt 1)
        { 
            $packageNameMasksToInclude = $linuxPackages | ConvertTo-Json
        }
    }

    Write-Output "Creating $($NextStageProperties.Count) maintenance stages using $($lastDeploymentDate.ToString('u')) as the reference date..." 

    foreach ($stageProperties in $NextStageProperties) 
    {
        $stageDayOfWeek = $lastDeploymentDate.AddDays($stageProperties.offsetDays).DayOfWeek
        $stageStartTime = $lastDeploymentDate.AddDays($stageProperties.offsetDays).ToString("u").Substring(0,16)
        $stageEndTime = $lastDeploymentDate.AddDays($stageProperties.offsetDays).AddHours(5).ToString("u").Substring(0,16)
        $maintenanceConfName = $stageProperties.stageName
        $maintenanceConfSubId = $MaintenanceConfigurationId.Split("/")[2]
        $maintenanceConfRG = $MaintenanceConfigurationId.Split("/")[4]
        $maintenanceConfDeploymentTemplateJson = @"
        {
            `"`$schema`": `"http://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#`",
            `"contentVersion`": `"1.0.0.0`",
            `"resources`": [
                {
                    `"type`": `"Microsoft.Maintenance/maintenanceConfigurations`",
                    `"apiVersion`": `"2023-04-01`",
                    `"name`": `"$($maintenanceConfName)`",
                    `"location`": `"$maintenanceConfLocation`",
                    `"tags`": $tags,
                    `"properties`": {
                        `"maintenanceScope`": `"InGuestPatch`",
                        `"installPatches`": {
                            `"linuxParameters`": {
                                `"classificationsToInclude`": null,
                                `"packageNameMasksToExclude`": null,
                                `"packageNameMasksToInclude`": $packageNameMasksToInclude
                            },
                            `"windowsParameters`": {
                                `"classificationsToInclude`": null,
                                `"kbNumbersToExclude`": null,
                                `"kbNumbersToInclude`": $kbNumbersToInclude
                            },
                            `"rebootSetting`": `"$rebootSetting`"
                        },
                        `"extensionProperties`": {
                            `"InGuestPatchMode`": `"User`"
                        },
                        `"maintenanceWindow`": {
                            `"startDateTime`": `"$stageStartTime`",
                            `"duration`": `"$maintenanceDuration`",
                            `"timeZone`": `"UTC`",
                            `"expirationDateTime`": `"$stageEndTime`",
                            `"recurEvery`": `"1Week $stageDayOfWeek`"
                        }
                    }
                }
            ]
        }
"@
        Write-Output "Creating/updating $maintenanceConfName maintenance configuration for the following packages:"
        Write-Output $linuxPatches
        Write-Output $windowsPackageNames

        $deploymentNameTemplate = "{0}-" + (Get-Date).ToString("yyMMddHHmmss")
        $templateFile = "./$deploymentNameTemplate.json"
        Set-Content -Path $templateFile -Value $maintenanceConfDeploymentTemplateJson
        if ((Get-AzContext).Subscription.Id -ne $maintenanceConfSubId)
        {
            Select-AzSubscription -SubscriptionId $maintenanceConfSubId | Out-Null
        }
        New-AzResourceGroupDeployment -TemplateFile $templateFile -ResourceGroupName $maintenanceConfRG -Name ($deploymentNameTemplate -f $maintenanceConfName) | Out-Null
        Write-Output "Maintenance configuration deployed."

        foreach ($scope in $stageProperties.scope)
        {
            $assignmentName = "$($maintenanceConfName)dynamicassignment1"
            $maintenanceConfAssignApiPath = "$scope/providers/Microsoft.Maintenance/configurationAssignments/$($assignmentName)?api-version=2023-04-01"
            $maintenanceConfAssignApiBody = @"
            {
                "properties": {
                  "maintenanceConfigurationId": "/subscriptions/$maintenanceConfSubId/resourceGroups/$maintenanceConfRG/providers/Microsoft.Maintenance/maintenanceConfigurations/$maintenanceConfName",
                  "resourceId": "$scope",
                  "filter": $($stageProperties.filter | ConvertTo-Json -Depth 3)
                }
            }
"@

            Write-Output "Creating/updating $assignmentName maintenance configuration assignment for scope $scope..."
            $response = Invoke-AzRestMethod -Path $maintenanceConfAssignApiPath -Method PUT -Payload $maintenanceConfAssignApiBody

            if ($response.StatusCode -eq 200)
            {
                Write-Output "Maintenance configuration assignment created/updated."
            }
            else
            {
                Write-Output "Maintenance configuration assignment creation/update failed (HTTP $($response.StatusCode))."
                Write-Output $response.Content
                throw "Maintenance configuration assignment creation/update failed (HTTP $($response.StatusCode))."
            }
        }
    }
}
else 
{
    Write-Output "No need to create further maintenance stages"
}