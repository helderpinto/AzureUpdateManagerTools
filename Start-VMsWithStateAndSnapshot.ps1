param
(
    [Parameter(Mandatory=$false)]
    [object] $WebhookData
)

$ErrorActionPreference = "Stop"

try{

    Connect-AzAccount -Identity

    # Install the Resource Graph module from PowerShell Gallery
    # Install-Module -Name Az.ResourceGraph

    $notificationPayload = ConvertFrom-Json -InputObject $WebhookData.RequestBody
    $maintenanceRunId = $notificationPayload[0].data.CorrelationId
    $runId = $maintenanceRunId.Split("/")[8] + "_" + $maintenanceRunId.Split("/")[-1]
    $resourceSubscriptionIds = $notificationPayload[0].data.ResourceSubscriptionIds

    if ($resourceSubscriptionIds.Count -eq 0) {
        Write-Output "Resource subscriptions are not present."
        break
    }

    Write-Output "Querying ARG to get machine details [MaintenanceRunId=$maintenanceRunId][ResourceSubscriptionIdsCount=$($resourceSubscriptionIds.Count)]"

    $argQuery = @"
        maintenanceresources 
        | where type =~ 'microsoft.maintenance/applyupdates'
        | where properties.correlationId =~ '$($maintenanceRunId)'
        | where id has '/providers/microsoft.compute/virtualmachines/'
        | project id, resourceId = tostring(properties.resourceId)
        | order by id asc
"@

    Write-Output "Arg Query Used: $argQuery"

    $allMachines = [System.Collections.ArrayList]@()
    $skipToken = $null

    do
    {
        $res = Search-AzGraph -Query $argQuery -First 1000 -SkipToken $skipToken -Subscription $resourceSubscriptionIds
        $skipToken = $res.SkipToken
        $allMachines.AddRange($res.Data)
    } while ($skipToken -ne $null -and $skipToken.Length -ne 0)

    if ($allMachines.Count -eq 0) {
        Write-Output "No Machines were found."
        break
    }

    $jobIDs= New-Object System.Collections.Generic.List[System.Object]
    $startableStates = "stopped" , "stopping", "deallocated", "deallocating"
    $startedMachines = @()

    $allMachines | ForEach-Object {
        $vmId =  $_.resourceId

        $split = $vmId -split "/";
        $subscriptionId = $split[2]; 
        $rg = $split[4];
        $name = $split[8];

        Write-Output ("Subscription Id: " + $subscriptionId)

        $mute = Set-AzContext -Subscription $subscriptionId
        $vm = Get-AzVM -ResourceGroupName $rg -Name $name -Status -DefaultProfile $mute
        $vmdetails = Get-AzVM -ResourceGroupName $rg -Name $name -DefaultProfile $mute
        $snapshot =  New-AzSnapshotConfig -SourceUri $vmdetails.StorageProfile.OsDisk.ManagedDisk.Id -Location $vmdetails.Location -CreateOption copy -Tag $vmdetails.Tags
        $timestamp = Get-Date -Format 'ddMMyyyy-HHmmss'
        $snapshotName = "$($name)_AUM_OSDisk_$timestamp"
        Write-Output "Creating snapshot $snapshotName"
        New-AzSnapshot -Snapshot $snapshot -SnapshotName $snapshotName -ResourceGroupName $rg
        $state = ($vm.Statuses[1].DisplayStatus -split " ")[1]
        if($state -in $startableStates) {
            Write-Output "Starting '$($name)' ..."
            $startedMachines += $vmId
            $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname, $sub) $context = Set-AzContext -Subscription $sub; Start-AzVM -ResourceGroupName $resource -Name $vmname -DefaultProfile $context} -ArgumentList $rg, $name, $subscriptionId
            $jobIDs.Add($newJob.Id)
        } else {
            Write-Output ($name + ": no action taken. State: " + $state)
        }
    }

    $startedMachinesCommaSeparated = $startedMachines -join ","
    $jobsList = $jobIDs.ToArray()
    if ($jobsList)
    {
        Write-Output "Waiting for machines to finish starting..."
        Wait-Job -Id $jobsList
    }

    foreach($id in $jobsList)
    {
        $job = Get-Job -Id $id
        if ($job.Error)
        {
            Write-Output $job.Error
        }
    }

    if (-not([string]::IsNullOrEmpty($startedMachinesCommaSeparated)))
    {
        $automationResources = Get-AzResource -ResourceType "Microsoft.Automation/automationAccounts"

        foreach ($automationResource in $automationResources)
        {
            $job = Get-AzAutomationJob -ResourceGroupName $automationResource.ResourceGroupName -AutomationAccountName $automationResource.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
            if (!([string]::IsNullOrEmpty($Job)))
            {
                $resourceGroup = $Job.ResourceGroupName
                $automationAccount = $Job.AutomationAccountName
                break;
            }
        }

        New-AzAutomationVariable -AutomationAccountName $automationAccount -ResourceGroupName $resourceGroup -Name $runId -Encrypted $False -Value $startedMachinesCommaSeparated
    }
}
catch{
    Write-Output "Canceling maintanence."
    $payload='{"properties": {"status": "Cancel"}}'
    Invoke-AzRestMethod -Path "$($notificationPayload[0].data.CorrelationId)?api-version=2023-09-01-preview" -Payload $payload -Method PUT
    throw "Failed runbook execution: $($_.Exception.Message)"
}
