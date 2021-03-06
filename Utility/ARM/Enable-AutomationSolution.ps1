<#
.SYNOPSIS
    This sample automation runbook onboards an Azure VM for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    The Runbook will search for an existing VM in both the onboarding VMs subscription and in the AA subscription.
    It is required to run this from an Automation account, and it's RunAs account will need contributor access rights to the subscription the onboaring VM is in.

    To set what Log Analytics workspace to use for Update and Change Tracking management (bypassing the logic that search for an existing onboarded VM),
    create the following AA variable assets:
        LASolutionSubscriptionId and populate with subscription ID of where the Log Analytics workspace is located
        LASolutionWorkspaceId and populate with the Workspace Id of the Log Analytics workspace

.DESCRIPTION
    This sample automation runbook onboards an Azure VM for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    This Runbook needs to be run from the Automation account that you wish to connect the new VM to.

.COMPONENT
    To predefine what Log Analytics workspace to use, create the following AA variable assets:
        LASolutionSubscriptionId
        LASolutionWorkspaceId

.PARAMETER VMSubscriptionId
    The name subscription id where the new VM to onboard is located.
    This will default to the same one as the Azure Automation account is located in if not specified. If you
    give a different subscription id then you need to make sure the RunAs account for
    this automation account is added as a contributor to this subscription also.

.PARAMETER VMResourceGroupName
    Required. The name of the resource group that the VM is a member of.

.PARAMETER VMName
    Required. The name of a specific VM that you want onboarded to the Updates or ChangeTracking solution

.PARAMETER SolutionType
    Required. The name of the solution to onboard to this Automation account.
    It must be either "Updates" or "ChangeTracking". ChangeTracking also includes the inventory solution.

.PARAMETER UpdateScopeQuery
    Optional. Default is true. Indicates whether to add this VM to the list of computers to enable for this solution.
    Solutions enable an optional scope configuration to be set on them that contains a query of computers
    to target the solution to. If you are calling this Runbook from a parent runbook that is onboarding
    multiple VMs concurrently, then you will want to set this to false and then do a final update of the
    search query with the list of onboarded computers to avoid any possible conflicts that this Runbook
    might do when reading, adding this VM, and updating the query since multiple versions of this Runbook
    might try and do this at the same time if run concurrently.

.Example
    .\Enable-AutomationSolution -VMSubscriptionId "1111-4fa371-22-46e4-a6ec-0bc48954" -VMName finance1 -VMResourceGroupName finance `
              -SolutionType Updates

.Example
    .\Enable-AutomationSolution -VMSubscriptionId "1111-4fa371-22-46e4-a6ec-0bc48954" -VMName finance1 -VMResourceGroupName finance `
             -SolutionType ChangeTracking -UpdateScopeQuery $False

.Example
    .\Enable-AutomationSolution -VMName finance1 -VMResourceGroupName finance -VMSubscriptionId "1111-4fa371-22-46e4-a6ec-0bc48954" `
             -SolutionType Updates

.NOTES
    AUTHOR: Automation Team
    Contibutor: Morten Lerudjordet
    LASTEDIT: February 13th, 2019
#>
#Requires -Version 5.0
Param (
    [Parameter(Mandatory = $False)]
    [String]
    $VMSubscriptionId,

    [Parameter(Mandatory = $True)]
    [String]
    $VMResourceGroupName,

    [Parameter(Mandatory = $True)]
    [String]
    $VMName,

    [Parameter(Mandatory = $True)]
    [ValidateSet("Updates", "ChangeTracking", IgnoreCase = $False)]
    [String]
    $SolutionType,

    [Parameter(Mandatory = $False)]
    [Boolean]
    $UpdateScopeQuery = $True
)
try
{
    $RunbookName = "Enable-AutomationSolution"
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
    # Check if AA asset variable is set  for Log Analytics workspace subscription ID to use
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
    $LogAnalyticsAgentExtensionName = "OMSExtension"
    $MMAApiVersion = "2018-10-01"
    $WorkspacesApiVersion = "2017-04-26-preview"
    $SolutionApiVersion = "2017-04-26-preview"
    #endregion

    # Fetch AA RunAs account detail from connection object asset
    $ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection" -ErrorAction Stop
    $Null = Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
    }

    # Set subscription of AA account
    $SubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
    }
    else
    {
        Write-Verbose -Message "Set subscription for AA to: $($SubscriptionContext.Subscription.Name)"
    }
    # set subscription of VM onboarded, else assume its in the same as the AA account
    if ($Null -eq $VMSubscriptionId -or "" -eq $VMSubscriptionId)
    {
        # Use the same subscription as the Automation account if not passed in
        $NewVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating azure VM context using subscription: $($NewVMSubscriptionContext.Subscription.Name)"

    }
    else
    {
        # VM is in a different subscription so set the context to this subscription
        $NewVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $VMSubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription where VM is. Make sure AA RunAs account has contributor rights" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating azure VM context using subscription: $($NewVMSubscriptionContext.Subscription.Name)"
        # Register Automation provider if it is not registered on the subscription
        $AutomationProvider = Get-AzureRMResourceProvider -ProviderNamespace Microsoft.Automation `
            -AzureRmContext $NewVMSubscriptionContext |  Where-Object {$_.RegistrationState -eq "Registered"}
        if ($Null -eq $AutomationProvider)
        {
            $ObjectOutPut = Register-AzureRmResourceProvider -ProviderNamespace Microsoft.Automation -AzureRmContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to register Microsoft.Automation provider in: $($NewVMSubscriptionContext.Subscription.Name)" -ErrorAction Stop
            }
        }
    }

    # set subscription of Log Analytic workspace used for Update Management and Change Tracking, else assume its in the same as the AA account
    if ($Null -ne $LogAnalyticsSolutionSubscriptionId)
    {
        # VM is in a different subscription so set the context to this subscription
        $LASubscriptionContext = Set-AzureRmContext -SubscriptionId $LogAnalyticsSolutionSubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription where Log Analytics workspace is" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating Log Analytics context using subscription: $($LASubscriptionContext.Subscription.Name)"
    }

    # Check if Log Analytics workspace is set through a AA asset
    if ($Null -eq $LogAnalyticsSolutionWorkspaceId)
    {
        # Set order to sort subscriptions by
        $SortOrder = @($NewVMSubscriptionContext.Subscription.Name, $SubscriptionContext.Subscription.Name)
        # Get all subscriptions the AA account has access to
        $AzureRmSubscriptions = Get-AzureRmSubscription |
            # Sort array so VM subscription will be search first for exiting onboarded VMs, then it will try AA subscription before moving on to others it has access to
        Sort-Object -Property {
            $SortRank = $SortOrder.IndexOf($($_.Name.ToLower()))
            if ($SortRank -ne -1)
            {
                $SortRank
            }
            else
            {
                [System.Double]::PositiveInfinity
            }
        }

        if ($Null -ne $AzureRmSubscriptions)
        {
            # Run through each until a VM with Microsoft Monitoring Agent is found
            $SubscriptionCounter = 0
            foreach ($AzureRMsubscription in $AzureRMsubscriptions)
            {
                # Set subscription context
                $OnboardedVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $AzureRmSubscription.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
                if ($oErr)
                {
                    Write-Error -Message "Failed to set azure context to subscription: $($AzureRmSubscription.Name)" -ErrorAction Continue
                    $oErr = $Null
                }
                if ($Null -ne $OnboardedVMSubscriptionContext)
                {
                    # Find existing VM that is already onboarded to the solution.
                    $VMExtensions = Get-AzureRmResource -ResourceType "Microsoft.Compute/virtualMachines/extensions" -AzureRmContext $OnboardedVMSubscriptionContext `
                        | Where-Object {$_.Name -like "*MicrosoftMonitoringAgent" -or $_.Name -like "*OmsAgentForLinux"}

                    # Find VM to use as template
                    if ($Null -ne $VMExtensions)
                    {
                        Write-Verbose -Message "Found $($VMExtensions.Count) VM(s) with Microsoft Monitoring Agent installed"
                        # Break out of loop if VM with Microsoft Monitoring Agent installed is found in a subscription
                        break
                    }
                }
                $SubscriptionCounter++
                if ($SubscriptionCounter -eq $AzureRmSubscriptions.Count)
                {
                    Write-Error -Message "Did not find any VM with Microsoft Monitoring Agent already installed. Install at least one in a subscription the AA RunAs account has access to" -ErrorAction Stop
                }
            }
            $VMCounter = 0
            foreach ($VMExtension in $VMExtensions)
            {
                if ($Null -ne $VMExtension.Name -and $Null -ne $VMExtension.ResourceGroupName)
                {
                    $ExistingVMExtension = Get-AzureRmVMExtension -ResourceGroup $VMExtension.ResourceGroupName -VMName ($VMExtension.Name).Split('/')[0] `
                        -AzureRmContext $OnboardedVMSubscriptionContext -Name ($VMExtension.Name).Split('/')[-1]
                }
                if ($Null -ne $ExistingVMExtension)
                {
                    Write-Verbose -Message "Retrieved extension config from VM: $($ExistingVMExtension.VMName)"
                    # Found VM with Microsoft Monitoring Agent installed
                    break
                }
                $VMCounter++
                if ($VMCounter -eq $VMExtensions.Count)
                {
                    Write-Error -Message "Failed to find an already onboarded VM with the Microsoft Monitoring Agent installed (Log Analytics) in subscription: $($NewVMSubscriptionContext.Subscription.Name), $($SubscriptionContext.Subscription.Nam)" -ErrorAction Stop
                }
            }
        }
        else
        {
            Write-Error -Message "Make sure the AA RunAs account has contributor rights on all subscriptions in play." -ErrorAction Stop
        }
        # Check if the existing VM is already onboarded
        if ($ExistingVMExtension.PublicSettings)
        {
            $PublicSettings = ConvertFrom-Json $ExistingVMExtension.PublicSettings
            if ($Null -eq $PublicSettings.workspaceId)
            {
                Write-Error -Message "This VM: $($ExistingVMExtension.VMName) is not onboarded. Please onboard first as it is used to collect information" -ErrorAction Stop
            }
            else
            {
                Write-Verbose -Message "VM: $($ExistingVMExtension.VMName) is correctly onboarded and can be used as template to onboard: $VMName"
            }
        }
        else
        {
            Write-Error -Message "Public settings for VM extension is empty" -ErrorAction Stop
        }
        # Get information about the workspace
        $WorkspaceInfo = Get-AzureRmOperationalInsightsWorkspace -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr `
            | Where-Object {$_.CustomerId -eq $PublicSettings.workspaceId}
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve Operational Insight workspace information" -ErrorAction Stop
        }
        if ($Null -ne $WorkspaceInfo)
        {
            # Workspace information
            $WorkspaceResourceGroupName = $WorkspaceInfo.ResourceGroupName
            $WorkspaceName = $WorkspaceInfo.Name
            $WorkspaceResourceId = $WorkspaceInfo.ResourceId
            $WorkspaceId = $WorkspaceInfo.CustomerId
            $WorkspaceLocation = $WorkspaceInfo.Location
        }
        else
        {
            Write-Error -Message "Failed to retrieve Log Analytics workspace information" -ErrorAction Stop
        }
        # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
        $SavedGroups = Get-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceResourceGroupName `
            -WorkspaceName $WorkspaceName -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve Log Analytics saved groups info" -ErrorAction Stop
        }
    }
    # Log Analytics workspace to use is set through AA assets
    else
    {
        if ($Null -ne $LASubscriptionContext)
        {
            # Get information about the workspace
            $WorkspaceInfo = Get-AzureRmOperationalInsightsWorkspace -AzureRmContext $LASubscriptionContext -ErrorAction Continue -ErrorVariable oErr `
                | Where-Object {$_.CustomerId -eq $LogAnalyticsSolutionWorkspaceId}
            if ($oErr)
            {
                Write-Error -Message "Failed to retrieve Log Analytics workspace information" -ErrorAction Stop
            }
            if ($Null -ne $WorkspaceInfo)
            {
                # Workspace information
                $WorkspaceResourceGroupName = $WorkspaceInfo.ResourceGroupName
                $WorkspaceName = $WorkspaceInfo.Name
                $WorkspaceResourceId = $WorkspaceInfo.ResourceId
                $WorkspaceId = $WorkspaceInfo.CustomerId
                $WorkspaceLocation = $WorkspaceInfo.Location
            }
            else
            {
                Write-Error -Message "Failed to retrieve Log Analytics workspace information" -ErrorAction Stop
            }
            # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
            $SavedGroups = Get-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceResourceGroupName `
                -WorkspaceName $WorkspaceName -AzureRmContext $LASubscriptionContext -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to retrieve Log Analytics saved groups info" -ErrorAction Stop
            }
        }
        else
        {
            Write-Error -Message "Log Analytics subscription context not set, check AA assets has correct value and AA runAs account has access to subscription." -ErrorAction Stop
        }
    }

    Write-Verbose -Message "Retrieving VM with following details: RG: $VMResourceGroupName, Name: $VMName, SubName: $($NewVMSubscriptionContext.Subscription.Name)"
    # Get details of the new VM to onboard.
    $NewVM = Get-AzureRMVM -ResourceGroupName $VMResourceGroupName -Name $VMName -Status `
        -AzureRmContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.Statuses.code -match "running"}
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve VM status data for: $VMName" -ErrorAction Stop
    }

    # Verify that VM is up and running before installing extension
    if ($Null -eq $NewVM)
    {
        Write-Error -Message "VM: $($NewVM.Name) is not running and can therefore not install extension" -ErrorAction Stop
    }
    else
    {
        $NewVM = Get-AzureRMVM -ResourceGroupName $VMResourceGroupName -Name $VMName `
            -AzureRmContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve VM data for: $VMName" -ErrorAction Stop
        }
        if ($Null -ne $NewVM)
        {
            # New VM information
            $VMResourceGroupName = $NewVM.ResourceGroupName
            $VMName = $NewVM.Name
            $VMLocation = $NewVM.Location
            $VMResourceId = $NewVM.Id
            $VMIdentityRequired = $false
        }
        else
        {
            Write-Error -Message "Failed to retrieve VM data for: $VMName" -ErrorAction Stop
        }
    }

    # Check if the VM is already onboarded to the Log Analytics workspace
    $Onboarded = Get-AzureRmVMExtension -ResourceGroup $VMResourceGroupName  -VMName $VMName `
        -Name $LogAnalyticsAgentExtensionName -AzureRmContext $NewVMSubscriptionContext -ErrorAction SilentlyContinue -ErrorVariable oErr
    if ($oErr)
    {
        if ($oErr.Exception.Message -match "ResourceNotFound")
        {
            # VM does not have OMS extension installed
            $Onboarded = $Null
        }
        else
        {
            Write-Error -Message "Failed to retrieve extension data from VM: $VMName" -ErrorAction Stop
        }

    }

    if ($Null -eq $Onboarded)
    {
        # Set up MMA agent information to onboard VM to the workspace
        if ($NewVM.StorageProfile.OSDisk.OSType -eq "Linux")
        {
            $MMAExentsionName = "OmsAgentForLinux"
            $MMAOStype = "OmsAgentForLinux"
            $MMATypeHandlerVersion = "1.7"
            Write-Output -InputObject "Deploying MMA agent to Linux VM"
        }
        elseif ($NewVM.StorageProfile.OSDisk.OSType -eq "Windows")
        {
            $MMAExentsionName = "MicrosoftMonitoringAgent"
            $MMAOStype = "MicrosoftMonitoringAgent"
            $MMATypeHandlerVersion = "1.0"
            Write-Output -InputObject "Deploying MMA agent to Windows VM"
        }
        else
        {
            Write-Error -Message "Could not determine OS of VM: $($NewVM.Name)"
        }
        #Region Windows & Linux ARM template
        # URL of original windows template: https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createMmaWindowsV3.json
        # URL of original linux template:   https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createMmaLinuxV3.json
        $ArmTemplate = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "vmName": {
            "defaultValue": "",
            "type": "String"
        },
        "vmLocation": {
            "defaultValue": "",
            "type": "String"
        },
        "vmResourceId": {
            "defaultValue": "",
            "type": "String"
        },
        "vmIdentityRequired": {
            "defaultValue": "false",
            "type": "Bool"
        },
        "workspaceName": {
            "defaultValue": "",
            "type": "String"
        },
        "workspaceId": {
            "defaultValue": "",
            "type": "String"
        },
        "workspaceResourceId": {
            "defaultValue": "",
            "type": "String"
        },
        "mmaExtensionName": {
            "defaultValue": "",
            "type": "String"
        },
        "apiVersion": {
            "defaultValue": "2018-10-01",
            "type": "String"
        },
        "workspacesApiVersion": {
            "defaultValue": "2017-04-26-preview",
            "type": "String"
        },
        "OStype": {
            "defaultValue": "",
            "type": "String"
        },
        "typeHandlerVersion": {
            "defaultValue": "",
            "type": "String"
        }
    },
    "variables": {
        "vmIdentity": {
            "type": "SystemAssigned"
        }
    },
    "resources": [
        {
            "type": "Microsoft.Compute/virtualMachines",
            "name": "[parameters('vmName')]",
            "apiVersion": "[parameters('apiVersion')]",
            "location": "[parameters('vmLocation')]",
            "identity": "[if(parameters('vmIdentityRequired'), variables('vmIdentity'), json('null'))]",
            "resources": [
                {
                    "type": "extensions",
                    "name": "[parameters('mmaExtensionName')]",
                    "apiVersion": "[parameters('apiVersion')]",
                    "location": "[parameters('vmLocation')]",
                    "properties": {
                        "publisher": "Microsoft.EnterpriseCloud.Monitoring",
                        "type": "[parameters('OStype')]",
                        "typeHandlerVersion": "[parameters('typeHandlerVersion')]",
                        "autoUpgradeMinorVersion": "true",
                        "settings": {
                            "workspaceId": "[parameters('workspaceId')]",
                            "azureResourceId": "[parameters('vmResourceId')]",
                            "stopOnMultipleConnections": "true"
                        },
                        "protectedSettings": {
                            "workspaceKey": "[listKeys(parameters('workspaceResourceId'), parameters('workspacesApiVersion')).primarySharedKey]"
                        }
                    },
                    "dependsOn": [
                        "[concat('Microsoft.Compute/virtualMachines/', parameters('vmName'))]"
                    ]
                }
            ]
        }
    ]
}
'@
        #Endregion
        # Create temporary file to store ARM template in
        $TempFile = New-TemporaryFile -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to create temporary file for Windows ARM template" -ErrorAction Stop
        }
        Out-File -InputObject $ArmTemplate -FilePath $TempFile.FullName -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to write arm template for log analytics agent installation to temp file" -ErrorAction Stop
        }

        $MMADeploymentParams = @{}
        $MMADeploymentParams.Add("vmName", $VMName)
        $MMADeploymentParams.Add("vmLocation", $VMLocation)
        $MMADeploymentParams.Add("vmResourceId", $VMResourceId)
        $MMADeploymentParams.Add("vmIdentityRequired", $VMIdentityRequired)
        $MMADeploymentParams.Add("workspaceName", $WorkspaceName)
        $MMADeploymentParams.Add("workspaceId", $WorkspaceId)
        $MMADeploymentParams.Add("workspaceResourceId", $WorkspaceResourceId)
        $MMADeploymentParams.Add("mmaExtensionName", $MMAExentsionName)
        $MMADeploymentParams.Add("apiVersion", $MMAApiVersion)
        $MMADeploymentParams.Add("workspacesApiVersion", $WorkspacesApiVersion)
        $MMADeploymentParams.Add("OStype", $MMAOStype)
        $MMADeploymentParams.Add("typeHandlerVersion", $MMATypeHandlerVersion)

        # Create deployment name
        $DeploymentName = "AutomationControl-PS-" + (Get-Date).ToFileTimeUtc()

        # Deploy solution to new VM
        $ObjectOutPut = New-AzureRmResourceGroupDeployment -ResourceGroupName $VMResourceGroupName -TemplateFile $TempFile.FullName `
            -Name $DeploymentName `
            -TemplateParameterObject $MMADeploymentParams `
            -AzureRmContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Deployment of Log Analytics agent failed" -ErrorAction Stop
        }
        else
        {
            Write-Output -InputObject $ObjectOutPut
            Write-Output -InputObject "VM: $VMName successfully onboarded with Log Analytics MMA agent"
        }

        # Remove temp file with arm template
        Remove-Item -Path $TempFile.FullName -Force
    }
    else
    {
        Write-Warning -Message "The VM: $VMName already has the Log Analytics MMA agent installed."
    }

    # Update scope query if necessary
    $SolutionGroup = $SavedGroups.Value | Where-Object {$_.Id -match "MicrosoftDefaultComputerGroup" -and $_.Properties.Category -eq $SolutionType}

    if ($Null -ne $SolutionGroup)
    {
        if (-not (($SolutionGroup.Properties.Query -match $VMResourceId) -and ($SolutionGroup.Properties.Query -match $VMName)) -and $UpdateScopeQuery)
        {
            # Original saved search query:
            # $DefaultQuery = "Heartbeat | where Computer in~ (`"`") or VMUUID in~ (`"`") | distinct Computer"

            # Make sure to only add VM id into VMUUID block, the same as is done by adding through the portal
            if ($SolutionGroup.Properties.Query -match 'VMUUID')
            {
                # Will leave the "" inside "VMUUID in~ () so can find out what is added by runbook (left of "") and what is added through portal (right of "")
                $NewQuery = $SolutionGroup.Properties.Query.Replace('VMUUID in~ (', "VMUUID in~ (`"$($NewVM.VmId)`",")
            }
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
                Write-Error -Message "Failed to write ARM template for solution onboarding to temp file" -ErrorAction Stop
            }
            # Add all of the parameters
            $QueryDeploymentParams = @{}
            $QueryDeploymentParams.Add("location", $WorkspaceLocation)
            $QueryDeploymentParams.Add("id", "/" + $SolutionGroup.Id)
            $QueryDeploymentParams.Add("resourceName", ($WorkspaceName + "/" + $SolutionType + "|" + "MicrosoftDefaultComputerGroup").ToLower())
            $QueryDeploymentParams.Add("category", $SolutionType)
            $QueryDeploymentParams.Add("displayName", "MicrosoftDefaultComputerGroup")
            $QueryDeploymentParams.Add("query", $NewQuery)
            $QueryDeploymentParams.Add("functionAlias", $SolutionType + "__MicrosoftDefaultComputerGroup")
            $QueryDeploymentParams.Add("etag", $SolutionGroup.ETag)
            $QueryDeploymentParams.Add("apiVersion", $SolutionApiVersion)

            # Create deployment name
            $DeploymentName = "AutomationControl-PS-" + (Get-Date).ToFileTimeUtc()

            $ObjectOutPut = New-AzureRmResourceGroupDeployment -ResourceGroupName $WorkspaceResourceGroupName -TemplateFile $TempFile.FullName `
                -Name $DeploymentName `
                -TemplateParameterObject $QueryDeploymentParams `
                -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to add VM: $VMName to solution: $SolutionType" -ErrorAction Stop
            }
            else
            {
                Write-Output -InputObject $ObjectOutPut
                Write-Output -InputObject "VM: $VMName successfully added to solution: $SolutionType"
            }

            # Remove temp file with arm template
            Remove-Item -Path $TempFile.FullName -Force
        }
        else
        {
            Write-Warning -Message "The VM: $VMName is already onboarded to solution: $SolutionType"
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