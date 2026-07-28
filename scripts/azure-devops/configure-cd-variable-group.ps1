# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(HelpMessage = 'Azure Developer CLI environment name under .azure, for example development. Leave empty to choose from .azure folders.')]
    [string]$azureEnv,
    [Parameter(HelpMessage = 'Azure DevOps organization URL, for example https://dev.azure.com/<organization-name>.')]
    [string]$OrganizationUrl,
    [Parameter(HelpMessage = 'Azure DevOps project that contains the CD pipeline.')]
    [string]$Project,
    [Parameter(HelpMessage = 'Azure DevOps variable group to create or update.')]
    [string]$VariableGroupName = 'contoso-real-estate-cd-development',
    [Parameter(HelpMessage = 'Deployment environment name used for naming the PAC deployment application.')]
    [string]$DeploymentEnvironmentName = 'development',
    [Parameter(HelpMessage = 'Azure tenant ID used by PAC service principal authentication. Leave empty to read AZURE_TENANT_ID from .azure/<env>/.env.')]
    [string]$PacDeployAzureTenantId,
    [Parameter(HelpMessage = 'Existing Entra application/client ID for PAC deployment. Leave empty to create or reuse cre-azure-devops-cd-<environment>.')]
    [string]$PacDeployClientId,
    [Parameter(HelpMessage = 'Existing Entra application client secret used by the Azure DevOps CD pipeline to authenticate PAC CLI. Leave empty to read PAC_DEPLOY_CLIENT_SECRET from the current process environment.')]
    [string]$PacDeployClientSecret,
    [Parameter(HelpMessage = 'Core Dev Dataverse environment URL. Controls and Core managed solutions are imported here.')]
    [string]$CorePacDeployEnvUrl,
    [Parameter(HelpMessage = 'Portal Dev Dataverse environment URL. Controls, Core, and Portal managed solutions are imported here.')]
    [string]$PortalPacDeployEnvUrl,
    [Parameter(HelpMessage = 'Power Pages portal URL in the Portal Dev environment. Leave empty to list and select the site with pac pages list.')]
    [string]$PortalUrl,
    [Parameter(HelpMessage = 'Optional Dataverse managed identity record id override for plugin assembly binding.')]
    [string]$OverridePluginManagedIdentityId,
    [Parameter(HelpMessage = 'Dataverse security role assigned to the deployment application user in both Core Dev and Portal Dev.')]
    [string]$PowerPlatformApplicationUserRole = 'System Administrator',
    [Parameter(HelpMessage = 'Skip az and pac login checks. Useful for WhatIf validation when target values are passed explicitly.')]
    [switch]$SkipLoginChecks
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\common\environment-variables.ps1"

$repoRoot = Get-RepositoryRoot
Set-Location -Path $repoRoot
. "$repoRoot\infra\scripts\common\payments-api-client-secret.ps1"

$envVars = GetRepositoryEnvironmentVariables -azureEnv $azureEnv -scriptDirectory $repoRoot

AssertCommandExists -Name 'az'
AssertCommandExists -Name 'pac'

$OrganizationUrl = GetRequiredValue -Name 'Azure DevOps organization URL, for example https://dev.azure.com/<organization-name>' -Value $OrganizationUrl
$Project = GetRequiredValue -Name 'Azure DevOps project name that contains the CD pipeline' -Value $Project

function Check-AzureDevOpsCli {
    $extension = az extension show --name azure-devops --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($extension | Out-String).Trim())) {
        throw "Azure CLI extension 'azure-devops' is required. Install it with: az extension add --name azure-devops"
    }

    InvokeExternalCommand -CommandDescription 'Check Azure DevOps CLI access' -ScriptBlock {
        az devops project show --organization $OrganizationUrl --project $Project --output none
    }
}

function Get-DeploymentEnvironmentVariable {
    param (
        [string]$SchemaName,
        [string]$Value
    )

    return [ordered]@{
        SchemaName = $SchemaName
        Value = $Value
    }
}

function Get-DeploymentConfigurationJson {
    param (
        [psobject]$EnvironmentVariables,
        [string]$PortalUrl,
        [string]$PortalPacDeployEnvUrl
    )

    $solutionPrefix = 'contoso'
    $apiAppName = 'PaymentsApi'
    $apiUserAccessScope = 'user_impersonation'

    $tenantId = GetRequiredValue -Name 'AZURE_TENANT_ID' -Value $EnvironmentVariables.AZURE_TENANT_ID
    $appHostUrl = (GetRequiredValue -Name 'SERVICE_API_URI' -Value $EnvironmentVariables.SERVICE_API_URI).TrimStart('https://')
    $appId = GetRequiredValue -Name 'ENTRA_API_CLIENT_APP_ID' -Value $EnvironmentVariables.ENTRA_API_CLIENT_APP_ID
    $appResourceUri = GetRequiredValue -Name 'SERVICE_API_RESOURCE_URI' -Value $EnvironmentVariables.SERVICE_API_RESOURCE_URI
    $scope = "$appResourceUri/$apiUserAccessScope"

    $environmentSettingsPath = Join-Path -Path $repoRoot -ChildPath 'src/core/solution/environment-settings.json'
    if (-not (Test-Path -Path $environmentSettingsPath)) {
        throw "Environment settings file not found: $environmentSettingsPath"
    }

    $environmentSettings = Get-Content -Path $environmentSettingsPath -Raw | ConvertFrom-Json
    $portalDataverseConnectionId = Get-PowerPlatformConnectionId `
        -EnvironmentUrl $PortalPacDeployEnvUrl `
        -ApiIdPrefix '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps' `
        -DisplayName 'Dataverse'
    $portalStripeConnectionId = Get-PowerPlatformConnectionId `
        -EnvironmentUrl $PortalPacDeployEnvUrl `
        -ApiIdPrefix '/providers/Microsoft.PowerApps/apis/shared_contoso-5fcontoso-20stripe-20api' `
        -DisplayName 'Contoso Stripe API'

    $deploymentConfiguration = [ordered]@{
        ContosoRealEstateCore = [ordered]@{
            data = @(
                'reference-data.zip',
                'sample-data.zip'
            )
            deploymentSettings = [ordered]@{
                EnvironmentVariables = @(
                    (Get-DeploymentEnvironmentVariable -SchemaName "${solutionPrefix}_${apiAppName}AppId" -Value $appId),
                    (Get-DeploymentEnvironmentVariable -SchemaName "${solutionPrefix}_${apiAppName}BaseUrl" -Value '/api'),
                    (Get-DeploymentEnvironmentVariable -SchemaName "${solutionPrefix}_${apiAppName}Host" -Value $appHostUrl),
                    (Get-DeploymentEnvironmentVariable -SchemaName "${solutionPrefix}_${apiAppName}ResourceUrl" -Value $appResourceUri),
                    (Get-DeploymentEnvironmentVariable -SchemaName "${solutionPrefix}_${apiAppName}Scope" -Value $scope),
                    (Get-DeploymentEnvironmentVariable -SchemaName "${solutionPrefix}_${apiAppName}TenantId" -Value $tenantId)
                )
                ConnectionReferences = @()
            }
            environmentSettings = $environmentSettings
        }
        ContosoRealEstatePortal = [ordered]@{
            deploymentSettings = [ordered]@{
                EnvironmentVariables = @(
                    (Get-DeploymentEnvironmentVariable -SchemaName 'contoso_ContosoRealEstatePortalUr' -Value $PortalUrl)
                )
                ConnectionReferences = @(
                    [ordered]@{
                        LogicalName = 'contoso_PortalBotQueries'
                        ConnectionId = $portalDataverseConnectionId
                        ConnectorId = '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps'
                    },
                    [ordered]@{
                        LogicalName = 'contoso_StripeAPI'
                        ConnectionId = $portalStripeConnectionId
                        ConnectorId = '/providers/Microsoft.PowerApps/apis/shared_contoso-5fcontoso-20stripe-20api-5f6a4f91c8025d1333'
                    }
                )
            }
        }
    }

    return $deploymentConfiguration | ConvertTo-Json -Depth 100 -Compress
}

function Get-AzureDevOpsVariableGroupId {
    $groupId = az pipelines variable-group list `
        --organization $OrganizationUrl `
        --project $Project `
        --query "[?name=='$VariableGroupName'].id | [0]" `
        --output tsv 2>&1
    AssertCommandSucceeded -CommandDescription "Get Azure DevOps variable group '$VariableGroupName'" -CommandOutput $groupId

    return ($groupId | Out-String).Trim()
}

function New-AzureDevOpsVariableGroup {
    param (
        [string]$TenantId
    )

    $createdGroupJson = az pipelines variable-group create `
        --organization $OrganizationUrl `
        --project $Project `
        --name $VariableGroupName `
        --authorize true `
        --variables PAC_DEPLOY_AZURE_TENANT_ID=$TenantId `
        --output json 2>&1
    AssertCommandSucceeded -CommandDescription "Create Azure DevOps variable group '$VariableGroupName'" -CommandOutput $createdGroupJson

    $createdGroup = $createdGroupJson | ConvertFrom-Json
    return [string]$createdGroup.id
}

function Ensure-AzureDevOpsEnvironment {
    $environmentListJson = az devops invoke `
        --organization $OrganizationUrl `
        --area distributedtask `
        --resource environments `
        --route-parameters project=$Project `
        --query-parameters name=$DeploymentEnvironmentName `
        --output json 2>&1
    AssertCommandSucceeded -CommandDescription "Get Azure DevOps environment '$DeploymentEnvironmentName'" -CommandOutput $environmentListJson

    $environmentList = $environmentListJson | ConvertFrom-Json
    $existingEnvironment = @($environmentList.value) | Where-Object { $_.name -eq $DeploymentEnvironmentName } | Select-Object -First 1
    if ($null -ne $existingEnvironment) {
        Write-Host "Azure DevOps environment '$DeploymentEnvironmentName' already exists." -ForegroundColor Green
        return [string]$existingEnvironment.id
    }

    $environmentBody = [ordered]@{
        name = $DeploymentEnvironmentName
        description = "Deployment environment for Contoso Real Estate $DeploymentEnvironmentName releases."
    } | ConvertTo-Json -Depth 5 -Compress
    $environmentBodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "azure-devops-environment-$DeploymentEnvironmentName.json"
    Set-Content -Path $environmentBodyPath -Value $environmentBody -Encoding utf8

    try {
        $createdEnvironmentJson = az devops invoke `
            --organization $OrganizationUrl `
            --area distributedtask `
            --resource environments `
            --route-parameters project=$Project `
            --http-method POST `
            --in-file $environmentBodyPath `
            --output json 2>&1
        AssertCommandSucceeded -CommandDescription "Create Azure DevOps environment '$DeploymentEnvironmentName'" -CommandOutput $createdEnvironmentJson

        $createdEnvironment = $createdEnvironmentJson | ConvertFrom-Json
        Write-Host "Created Azure DevOps environment '$DeploymentEnvironmentName'." -ForegroundColor Green
        return [string]$createdEnvironment.id
    }
    finally {
        Remove-Item -Path $environmentBodyPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-AzureDevOpsVariable {
    param (
        [string]$GroupId,
        [string]$Name,
        [string]$Value,
        [switch]$Secret
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $existingVariablesJson = az pipelines variable-group variable list `
        --organization $OrganizationUrl `
        --project $Project `
        --group-id $GroupId `
        --output json 2>&1
    AssertCommandSucceeded -CommandDescription "List variables in Azure DevOps variable group '$VariableGroupName'" -CommandOutput $existingVariablesJson
    $existingVariables = $existingVariablesJson | ConvertFrom-Json
    $exists = $null -ne $existingVariables.PSObject.Properties[$Name]

    $commandName = if ($exists) { 'update' } else { 'create' }
    $commandDescription = if ($exists) { "Update Azure DevOps variable '$Name'" } else { "Create Azure DevOps variable '$Name'" }

    if ($Secret) {
        $envVarName = "AZURE_DEVOPS_EXT_PIPELINE_VAR_$Name"
        try {
            Set-Item -Path "Env:$envVarName" -Value $Value
            if ($exists) {
                InvokeExternalCommand -CommandDescription $commandDescription -ScriptBlock {
                    az pipelines variable-group variable update `
                        --organization $OrganizationUrl `
                        --project $Project `
                        --group-id $GroupId `
                        --name $Name `
                        --secret true `
                        --prompt-value true `
                        --output none
                }
            }
            else {
                InvokeExternalCommand -CommandDescription $commandDescription -ScriptBlock {
                    az pipelines variable-group variable create `
                        --organization $OrganizationUrl `
                        --project $Project `
                        --group-id $GroupId `
                        --name $Name `
                        --secret true `
                        --output none
                }
            }
        }
        finally {
            Remove-Item -Path "Env:$envVarName" -ErrorAction SilentlyContinue
        }

        return
    }

    InvokeExternalCommand -CommandDescription $commandDescription -ScriptBlock {
        az pipelines variable-group variable $commandName `
            --organization $OrganizationUrl `
            --project $Project `
            --group-id $GroupId `
            --name $Name `
            --value $Value `
            --output none
    }
}

if (-not $SkipLoginChecks) {
    CheckAZCLI
    CheckPACCLI
    Check-AzureDevOpsCli
}

if ([string]::IsNullOrWhiteSpace($PacDeployAzureTenantId) -and -not [string]::IsNullOrWhiteSpace($envVars.AZURE_TENANT_ID)) {
    $PacDeployAzureTenantId = $envVars.AZURE_TENANT_ID
}

if ([string]::IsNullOrWhiteSpace($CorePacDeployEnvUrl)) {
    $CorePacDeployEnvUrl = Select-PowerPlatformEnvironmentUrl -Purpose "Core Dev Dataverse environment for importing ContosoRealEstateCustomControls and ContosoRealEstateCore in '$DeploymentEnvironmentName'"
}

if ([string]::IsNullOrWhiteSpace($CorePacDeployEnvUrl)) {
    throw "PAC_DEPLOY_CORE_ENV_URL is required. Pass -CorePacDeployEnvUrl with the Core Dev Dataverse environment URL."
}

if ([string]::IsNullOrWhiteSpace($PortalPacDeployEnvUrl)) {
    $PortalPacDeployEnvUrl = Select-PowerPlatformEnvironmentUrl `
        -Purpose "Portal Dev Dataverse environment for importing ContosoRealEstateCustomControls, ContosoRealEstateCore, and ContosoRealEstatePortal in '$DeploymentEnvironmentName'" `
        -ExcludedEnvironmentUrls @($CorePacDeployEnvUrl)
}

if ([string]::IsNullOrWhiteSpace($PortalPacDeployEnvUrl)) {
    throw "PAC_DEPLOY_PORTAL_ENV_URL is required. Pass -PortalPacDeployEnvUrl with the Portal Dev Dataverse environment URL."
}

if ($CorePacDeployEnvUrl.TrimEnd('/') -eq $PortalPacDeployEnvUrl.TrimEnd('/')) {
    throw 'PAC_DEPLOY_CORE_ENV_URL and PAC_DEPLOY_PORTAL_ENV_URL must be different Dataverse environments.'
}

if ([string]::IsNullOrWhiteSpace($PortalUrl)) {
    $PortalUrl = Select-PowerPagesPortalUrl -EnvironmentUrl $PortalPacDeployEnvUrl -Purpose "Power Pages site in Portal Dev for '$DeploymentEnvironmentName'"
}

$tenantId = GetRequiredValue -Name 'Azure tenant ID for PAC deployment (PAC_DEPLOY_AZURE_TENANT_ID)' -Value $PacDeployAzureTenantId
$pluginManagedIdentityAppId = GetRequiredValue -Name 'Plugin managed identity application/client ID from the Azure API deployment (PLUGIN_MANAGED_IDENTITY_APP_ID)' -Value $envVars.ENTRA_API_CLIENT_APP_ID
$spnName = "cre-azure-devops-cd-$DeploymentEnvironmentName"
$deploymentConfigJson = Get-DeploymentConfigurationJson -EnvironmentVariables $envVars -PortalUrl $PortalUrl -PortalPacDeployEnvUrl $PortalPacDeployEnvUrl
$existingApplicationId = $null

if ([string]::IsNullOrWhiteSpace($PacDeployClientId)) {
    $applicationIdOutput = az ad sp list --display-name $spnName --query '[0].appId' -o tsv 2>&1
    AssertCommandSucceeded -CommandDescription "Get service principal '$spnName'" -CommandOutput $applicationIdOutput
    $existingApplicationId = ($applicationIdOutput | Out-String).Trim()
}

if ([string]::IsNullOrWhiteSpace($PacDeployClientSecret) -and -not [string]::IsNullOrWhiteSpace($env:PAC_DEPLOY_CLIENT_SECRET)) {
    $PacDeployClientSecret = $env:PAC_DEPLOY_CLIENT_SECRET
}

Write-Host "Azure DevOps organization: $OrganizationUrl" -ForegroundColor Cyan
Write-Host "Azure DevOps project: $Project" -ForegroundColor Cyan
Write-Host "Variable group: $VariableGroupName" -ForegroundColor Cyan
Write-Host "Azure environment: $($envVars.AZURE_ENV_NAME)" -ForegroundColor Cyan
Write-Host "Core Power Platform environment URL: $CorePacDeployEnvUrl" -ForegroundColor Cyan
Write-Host "Portal Power Platform environment URL: $PortalPacDeployEnvUrl" -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($Project, "configure Azure DevOps CD environment and variable group for '$DeploymentEnvironmentName'")) {
    $applicationId = $PacDeployClientId

    if ([string]::IsNullOrWhiteSpace($applicationId)) {
        $applicationId = $existingApplicationId
    }

    if ([string]::IsNullOrWhiteSpace($applicationId)) {
        Write-Host "Creating service principal '$spnName'." -ForegroundColor Green
        InvokeExternalCommand -CommandDescription "Create Power Platform service principal '$spnName'" -ScriptBlock {
            pac admin create-service-principal --name $spnName
        }

        $createdApplicationIdOutput = az ad sp list --display-name $spnName --query '[0].appId' -o tsv 2>&1
        AssertCommandSucceeded -CommandDescription "Get created service principal '$spnName'" -CommandOutput $createdApplicationIdOutput
        $applicationId = ($createdApplicationIdOutput | Out-String).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($applicationId)) {
        throw "Unable to determine the application ID for '$spnName'."
    }

    $PacDeployClientSecret = GetRequiredValue -Name 'Azure DevOps CD PAC CLI Entra app client secret (PAC_DEPLOY_CLIENT_SECRET)' -Value $PacDeployClientSecret

    $paymentsApiClientSecretInfo = Get-PaymentsApiClientSecretInfo `
        -EnvironmentVariables $envVars `
        -AzureEnv $envVars.AZURE_ENV_NAME `
        -ScriptsRoot (Join-Path -Path $repoRoot -ChildPath 'infra\scripts')

    Ensure-AzureDevOpsEnvironment | Out-Null

    $groupId = Get-AzureDevOpsVariableGroupId
    if ([string]::IsNullOrWhiteSpace($groupId)) {
        $groupId = New-AzureDevOpsVariableGroup -TenantId $tenantId
    }

    Set-AzureDevOpsVariable -GroupId $groupId -Name 'PAC_DEPLOY_AZURE_TENANT_ID' -Value $tenantId
    Set-AzureDevOpsVariable -GroupId $groupId -Name 'PAC_DEPLOY_CLIENT_ID' -Value $applicationId
    Set-AzureDevOpsVariable -GroupId $groupId -Name 'PAC_DEPLOY_CLIENT_SECRET' -Value $PacDeployClientSecret -Secret
    Set-AzureDevOpsVariable -GroupId $groupId -Name 'PAC_DEPLOY_CORE_ENV_URL' -Value $CorePacDeployEnvUrl
    Set-AzureDevOpsVariable -GroupId $groupId -Name 'PAC_DEPLOY_PORTAL_ENV_URL' -Value $PortalPacDeployEnvUrl
    Set-AzureDevOpsVariable -GroupId $groupId -Name 'PLUGIN_MANAGED_IDENTITY_APP_ID' -Value $pluginManagedIdentityAppId
    Set-AzureDevOpsVariable -GroupId $groupId -Name 'PAYMENTS_API_CLIENT_SECRET' -Value $paymentsApiClientSecretInfo.Value -Secret
    Set-AzureDevOpsVariable -GroupId $groupId -Name 'PAC_DEPLOY_CONFIG' -Value $deploymentConfigJson
    Set-AzureDevOpsVariable -GroupId $groupId -Name 'OVERRIDE_PLUGIN_MANAGED_IDENTITY_ID' -Value $OverridePluginManagedIdentityId

    Add-PowerPlatformApplicationUser -EnvironmentUrl $CorePacDeployEnvUrl -ApplicationId $applicationId -Role $PowerPlatformApplicationUserRole
    Add-PowerPlatformApplicationUser -EnvironmentUrl $PortalPacDeployEnvUrl -ApplicationId $applicationId -Role $PowerPlatformApplicationUserRole
}

Write-Host ''
Write-Host "Azure DevOps CD variable group '$VariableGroupName' configuration complete." -ForegroundColor Green
Write-Host 'CD pipeline: requires the variable group, Power Platform Build Tools extension, and the development Azure DevOps environment.' -ForegroundColor Green