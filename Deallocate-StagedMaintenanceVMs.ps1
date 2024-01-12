param
(
    [Parameter(Mandatory=$false)]
    [object] $WebhookData
)

# https://learn.microsoft.com/en-us/azure/update-manager/tutorial-webhooks-using-runbooks?tabs=portal%2Cscript-off

Connect-AzAccount -Identity

# Install the Resource Graph module from PowerShell Gallery
# Install-Module -Name Az.ResourceGraph

$notificationPayload = ConvertFrom-Json -InputObject $WebhookData.RequestBody
$maintenanceRunId = $notificationPayload[0].data.CorrelationId
$resourceSubscriptionIds = $notificationPayload[0].data.ResourceSubscriptionIds

if ($resourceSubscriptionIds.Count -eq 0) {
    Write-Output "Resource subscriptions are not present."
    break
}

Start-Sleep -Seconds 30
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
$stoppableStates = "starting", "running"

$allMachines | ForEach-Object {
    $vmId =  $_.resourceId

    $split = $vmId -split "/";
    $subscriptionId = $split[2]; 
    $rg = $split[4];
    $name = $split[8];

    Write-Output ("Subscription Id: " + $subscriptionId)

    $mute = Set-AzContext -Subscription $subscriptionId
    $vm = Get-AzVM -ResourceGroupName $rg -Name $name -Status -DefaultProfile $mute

    $state = ($vm.Statuses[1].DisplayStatus -split " ")[1]
    if($state -in $stoppableStates) {
        Write-Output "Stopping '$($name)' ..."

        $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname, $sub) $context = Set-AzContext -Subscription $sub; Stop-AzVM -ResourceGroupName $resource -Name $vmname -Force -DefaultProfile $context} -ArgumentList $rg, $name, $subscriptionId
        $jobIDs.Add($newJob.Id)
    } else {
        Write-Output ($name + ": no action taken. State: " + $state) 
    }
}

$jobsList = $jobIDs.ToArray()
if ($jobsList)
{
    Write-Output "Waiting for machines to finish stop operation..."
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