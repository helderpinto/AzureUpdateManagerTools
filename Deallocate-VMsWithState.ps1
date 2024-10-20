param
(
    [Parameter(Mandatory=$false)]
    [object] $WebhookData
)

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

$machinesToShutdown = Get-AutomationVariable -Name $runId -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($machinesToShutdown))
{
    Write-Output "No machines to turn off"
}
else
{
    $vmIds = $machinesToShutdown -split ","    

    $jobIDs= New-Object System.Collections.Generic.List[System.Object]
    $stoppableStates = "starting", "running"
    
    $vmIds | ForEach-Object {
        $vmId =  $_
    
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

    $automationResources = Get-AzResource -ResourceType Microsoft.Automation/AutomationAccounts

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
    
    Remove-AzAutomationVariable -AutomationAccountName $automationAccount -ResourceGroupName $resourceGroup -name $runID    
}