<#
.SYNOPSIS
    Maintanance Runbook to update and remove retired VMs from solution saved searched in Log Analytics.
    Solutions supported are Update Management and Change Tracking.

    To set what Log Analytics workspace to use for Update and Change Tracking management (bypassing the logic that search for an existing onboarded VM),
    create the following AA variable assets:
        LASolutionSubscriptionId and populate with subscription ID of where the Log Analytics workspace is located
        LASolutionWorkspaceId and populate with the Workspace Id of the Log Analytics workspace

.DESCRIPTION
    This Runbooks assumes both Azure Automation account and Log Analytics account is in the same subscription
    For best effect schedule this Runbook to run on a recurring schedule to periodically search for retired VMs.

.COMPONENT
    To predefine what Log Analytics workspace to use, create the following AA variable assets:
        LASolutionSubscriptionId
        LASolutionWorkspaceId

.NOTES
    AUTHOR: Morten Lerudjordet
    LASTEDIT: February 13th, 2019
#>
#Requires -Version 5.0
try
{
    $RunbookName = "Remove-RetiredVMsAutomationSolution"
    Write-Output -InputObject "Starting Runbook: $RunbookName at time: $(get-Date -format r).`nRunning PS version: $($PSVersionTable.PSVersion)`nOn host: $($env:computername)"

    $VerbosePreference = "silentlycontinue"
    Import-Module -Name AzureRM.Profile, AzureRM.Automation, AzureRM.OperationalInsights, AzureRM.Compute, AzureRM.Resources -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to load needed modules for Runbook, check that AzureRM.Automation, AzureRM.OperationalInsights, AzureRM.Compute and AzureRM.Resources is imported into Azure Automation" -ErrorAction Stop
    }
    $VerbosePreference = "Continue"

    #region Variables
    ############################################################
    #   Variables
    ############################################################
    $LogAnalyticsSolutionSubscriptionId = Get-AutomationVariable -Name "LASolutionSubscriptionId" -ErrorAction SilentlyContinue
    if ($Null -ne $LogAnalyticsSolutionSubscriptionId)
    {
        Write-Output -InputObject "Using AA asset variable for Log Analytics subscription id"
    }
    else
    {
        Write-Output -InputObject "Will try to discover Log Analytics subscription id"
    }

    # Check if AA asset variable is set  for Log Analytics workspace ID to use
    $LogAnalyticsSolutionWorkspaceId = Get-AutomationVariable -Name "LASolutionWorkspaceId" -ErrorAction SilentlyContinue
    if ($Null -ne $LogAnalyticsSolutionWorkspaceId)
    {
        Write-Output -InputObject "Using AA asset variable for Log Analytics workspace id"
    }
    else
    {
        Write-Output -InputObject "Will try to discover Log Analytics workspace id"
    }
    $SolutionApiVersion = "2017-04-26-preview"
    $SolutionTypes = @("Updates", "ChangeTracking")
    #endregion

    # Authenticate to Azure
    $ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
    $Null = Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
    }

    # Set subscription to work against
    $SubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
    }

    # Get all VMs AA account has read access to
    $AllAzureVMs = Get-AzureRmSubscription |
        Foreach-object { $Context = Set-AzureRmContext -SubscriptionId $_.SubscriptionId; Get-AzureRmVM -AzureRmContext $Context} |
        Select-Object -Property Name, VmId

    if($Null -ne $LogAnalyticsSolutionWorkspaceId)
    {
        $WorkspaceInfo = Get-AzureRmOperationalInsightsWorkspace -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr |
            Where-Object {$_.CustomerId -eq $LogAnalyticsSolutionWorkspaceId}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve Log Analytic workspace info" -ErrorAction Stop
        }
    }
    else
    {
        # Get information about the workspace
        $WorkspaceInfo = Get-AzureRmOperationalInsightsWorkspace -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve Log Analytic workspace info" -ErrorAction Stop
        }
        if ($Null -eq $WorkspaceInfo -and $WorkspaceInfo.Count -gt 1)
        {
            Write-Error -Message "Failed to retrieve Log Analytic workspace information. Or multiple Log Analytic workspaces was returned" -ErrorAction Stop
        }
    }


    # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
    if($Null -ne $WorkspaceInfo)
    {
        $SavedGroups = Get-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceInfo.ResourceGroupName `
            -WorkspaceName $WorkspaceInfo.Name -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve Operational Insight saved groups info" -ErrorAction Stop
        }
    }

    foreach ($SolutionType in $SolutionTypes)
    {
        Write-Output -InputObject "Processing solution type: $SolutionType"
        $SolutionGroup = $SavedGroups.Value | Where-Object {$_.Id -match "MicrosoftDefaultComputerGroup" -and $_.Properties.Category -eq $SolutionType}
        # Check that solution is deployed
        if ($Null -ne $SolutionGroup)
        {
            $SolutionQuery = $SolutionGroup.Properties.Query

            if ($Null -ne $SolutionQuery)
            {
                # Get all VMs from Computer and VMUUID  in Query
                $VmIds = (((Select-String -InputObject $SolutionQuery -Pattern "VMUUID in~ \((.*?)\)").Matches.Groups[1].Value).Split(",")).Replace("`"", "") | Where-Object {$_} | Select-Object -Property @{l = "VmId"; e = {$_}}
                $VmNames = (((Select-String -InputObject $SolutionQuery -Pattern "Computer in~ \((.*?)\)").Matches.Groups[1].Value).Split(",")).Replace("`"", "")  | Where-Object {$_} | Select-Object -Property @{l = "Name"; e = {$_}}

                # Get VM Ids that are no longer alive
                if ($Null -ne $VmIds)
                {
                    $DeletedVmIds = Compare-Object -ReferenceObject $VmIds -DifferenceObject $AllAzureVMs -Property VmId | Where-Object {$_.SideIndicator -eq "<="}
                    # Remove deleted VM Ids from saved search query
                    foreach ($DeletedVmId in $DeletedVmIds)
                    {
                        if ($Null -eq $UpdatedQuery)
                        {
                            $UpdatedQuery = $SolutionQuery.Replace("`"$($DeletedVmId.VmId)`",", "")
                            Write-Output -InputObject "Removing VM with Id: $($DeletedVmId.VmId) from saved search"
                        }
                        else
                        {
                            $UpdatedQuery = $UpdatedQuery.Replace("`"$($DeletedVmId.VmId)`",", "")
                            Write-Output -InputObject "Removing VM with Id: $($DeletedVmId.VmId) from saved search"
                        }

                    }
                }
                else
                {
                    Write-Output -InputObject "There are no VM Ids in saved search"
                }

                # Get VM Names that are no longer alive
                if ($Null -ne $VmNames)
                {
                    $DeletedVms = Compare-Object -ReferenceObject $VmNames -DifferenceObject $AllAzureVMs -Property Name | Where-Object {$_.SideIndicator -eq "<="}
                    # Remove deleted VM Names from saved search query
                    foreach ($DeletedVm in $DeletedVms)
                    {
                        if ($Null -eq $UpdatedQuery)
                        {
                            $UpdatedQuery = $SolutionQuery.Replace("`"$($DeletedVm.Name)`",", "")
                            Write-Output -InputObject "Removing VM with Name: $($DeletedVmId.Name) from saved search"
                        }
                        else
                        {
                            $UpdatedQuery = $UpdatedQuery.Replace("`"$($DeletedVm.Name)`",", "")
                            Write-Output -InputObject "Removing VM with Name: $($DeletedVmId.Name) from saved search"
                        }
                    }
                }
                else
                {
                    Write-Output -InputObject "There are no VM Names in saved search"
                }

                if ($Null -ne $UpdatedQuery)
                {
                    #Region Solution Onboarding ARM Template
                    # ARM template to deploy log analytics agent extension for both Linux and Windows
                    # URL to template: https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createKQLScopeQueryV2.json
                    $ArmTemplate = @'
{
    "$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "location": {
            "type": "string",
            "defaultValue": ""
        },
        "id": {
            "type": "string",
            "defaultValue": ""
        },
        "resourceName": {
            "type": "string",
            "defaultValue": ""
        },
        "category": {
            "type": "string",
            "defaultValue": ""
        },
        "displayName": {
            "type": "string",
            "defaultValue": ""
        },
        "query": {
            "type": "string",
            "defaultValue": ""
        },
        "functionAlias": {
            "type": "string",
            "defaultValue": ""
        },
        "etag": {
            "type": "string",
            "defaultValue": ""
        },
        "apiVersion": {
            "defaultValue": "2017-04-26-preview",
            "type": "String"
        }
    },
    "resources": [
        {
            "apiVersion": "[parameters('apiVersion')]",
            "type": "Microsoft.OperationalInsights/workspaces/savedSearches",
            "location": "[parameters('location')]",
            "name": "[parameters('resourceName')]",
            "id": "[parameters('id')]",
            "properties": {
                "displayname": "[parameters('displayName')]",
                "category": "[parameters('category')]",
                "query": "[parameters('query')]",
                "functionAlias": "[parameters('functionAlias')]",
                "etag": "[parameters('etag')]",
                "tags": [
                    {
                        "Name": "Group", "Value": "Computer"
                    }
                ]
            }
        }
    ]
}
'@
                    #Endregion
                    # Create temporary file to store ARM template in
                    $TempFile = New-TemporaryFile -ErrorAction Continue -ErrorVariable oErr
                    if ($oErr)
                    {
                        Write-Error -Message "Failed to create temporary file for solution ARM template" -ErrorAction Stop
                    }
                    Out-File -InputObject $ArmTemplate -FilePath $TempFile.FullName -ErrorAction Continue -ErrorVariable oErr
                    if ($oErr)
                    {
                        Write-Error -Message "Failed to write ARM template for solution to temp file" -ErrorAction Stop
                    }
                    # Add all of the parameters
                    $QueryDeploymentParams = @{}
                    $QueryDeploymentParams.Add("location", $WorkspaceInfo.Location)
                    $QueryDeploymentParams.Add("id", "/" + $SolutionGroup.Id)
                    $QueryDeploymentParams.Add("resourceName", ($WorkspaceInfo.Name + "/" + $SolutionType + "|" + "MicrosoftDefaultComputerGroup").ToLower())
                    $QueryDeploymentParams.Add("category", $SolutionType)
                    $QueryDeploymentParams.Add("displayName", "MicrosoftDefaultComputerGroup")
                    $QueryDeploymentParams.Add("query", $UpdatedQuery)
                    $QueryDeploymentParams.Add("functionAlias", $SolutionType + "__MicrosoftDefaultComputerGroup")
                    $QueryDeploymentParams.Add("etag", $SolutionGroup.ETag)
                    $QueryDeploymentParams.Add("apiVersion", $SolutionApiVersion)

                    # Create deployment name
                    $DeploymentName = "AutomationControl-PS-" + (Get-Date).ToFileTimeUtc()

                    $ObjectOutPut = New-AzureRmResourceGroupDeployment -ResourceGroupName $WorkspaceInfo.ResourceGroupName -TemplateFile $TempFile.FullName `
                        -Name $DeploymentName `
                        -TemplateParameterObject $QueryDeploymentParams `
                        -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
                    if ($oErr)
                    {
                        Write-Error -Message "Failed to update solution type: $SolutionType saved search" -ErrorAction Stop
                    }
                    else
                    {
                        Write-Output -InputObject $ObjectOutPut
                        Write-Output -InputObject "Successfully updated solution type: $SolutionType saved search"
                    }

                    # Remove temp file with arm template
                    Remove-Item -Path $TempFile.FullName -Force
                }
                else
                {
                    Write-Output -InputObject "No retired VMs found, therefore no update to solution saved search will be done"
                }
            }
            else
            {
                Write-Warning -Message "Failed to retrieve saved search query for solution: $SolutionType"
            }
        }
        else
        {
            Write-Output -InputObject "Solution: $SolutionType is not deployed"
        }
    }
}
catch
{
    if ($_.Exception.Message)
    {
        Write-Error -Message "$($_.Exception.Message)" -ErrorAction Continue
    }
    else
    {
        Write-Error -Message "$($_.Exception)" -ErrorAction Continue
    }
    throw "$($_.Exception)"
}
finally
{
    Write-Output -InputObject "Runbook: $RunbookName ended at time: $(get-Date -format r)"
}
