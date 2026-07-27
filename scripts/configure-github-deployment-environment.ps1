# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(HelpMessage = 'Azure Developer CLI environment name under .azure, for example development. Leave empty to choose from .azure folders.')]
    [string]$azureEnv,
    [Parameter(HelpMessage = 'GitHub repository in owner/name format. Leave empty to detect it from the git remote.')]
    [string]$Repository,
    [Parameter(HelpMessage = 'Git remote name used to detect the GitHub repository when Repository is not provided.')]
    [string]$Remote = 'origin',
    [Parameter(HelpMessage = 'GitHub deployment environment to configure. Defaults to development.')]
    [string]$GitHubEnvironmentName = 'development',
    [Parameter(HelpMessage = 'Azure tenant ID used by PAC GitHub OIDC authentication. Leave empty to read AZURE_TENANT_ID from .azure/<env>/.env.')]
    [string]$PacDeployAzureTenantId,
    [Parameter(HelpMessage = 'Existing Entra application/client ID for PAC deployment. Leave empty to create or reuse cre-github-workflows-<environment>.')]
    [string]$PacDeployClientId,
    [Parameter(HelpMessage = 'Core Dev Dataverse environment URL. Controls and Core managed solutions are imported here.')]
    [string]$CorePacDeployEnvUrl,
    [Parameter(HelpMessage = 'Portal Dev Dataverse environment URL. Controls, Core, and Portal managed solutions are imported here.')]
    [string]$PortalPacDeployEnvUrl,
    [Parameter(HelpMessage = 'Power Pages portal URL in the Portal Dev environment. Leave empty to list and select the site with pac pages list.')]
    [string]$PortalUrl,
    [Parameter(HelpMessage = 'Dataverse security role assigned to the deployment application user in both Core Dev and Portal Dev.')]
    [string]$PowerPlatformApplicationUserRole = 'System Administrator',
    [Parameter(HelpMessage = 'Skip gh, az, and pac login checks. Useful for WhatIf validation when the target values are passed explicitly.')]
    [switch]$SkipLoginChecks
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\environment-variables.ps1"

$repoRoot = Get-RepositoryRoot
Set-Location -Path $repoRoot
. "$repoRoot\infra\scripts\common\payments-api-client-secret.ps1"

$envVars = GetRepositoryEnvironmentVariables -azureEnv $azureEnv -scriptDirectory $repoRoot

AssertCommandExists -Name 'git'
AssertCommandExists -Name 'az'
AssertCommandExists -Name 'pac'
AssertCommandExists -Name 'gh'

if (-not $SkipLoginChecks) {
    CheckGitHubCLI
    CheckAZCLI
    CheckPACCLI
}

if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = GetGitHubRepositoryName -remoteNames @($Remote)
}

if ($GitHubEnvironmentName -eq 'solution-checker') {
    throw "The 'solution-checker' GitHub environment is configured by scripts/configure-github-build-validate.ps1. Use this script only for deployment environments such as development, testing, or production."
}

if ([string]::IsNullOrWhiteSpace($PacDeployAzureTenantId) -and -not [string]::IsNullOrWhiteSpace($envVars.AZURE_TENANT_ID)) {
    $PacDeployAzureTenantId = $envVars.AZURE_TENANT_ID
}

if ([string]::IsNullOrWhiteSpace($CorePacDeployEnvUrl)) {
    $CorePacDeployEnvUrl = Select-PowerPlatformEnvironmentUrl -Purpose "Core Dev Dataverse environment for importing ContosoRealEstateCustomControls and ContosoRealEstateCore in '$GitHubEnvironmentName'"
}

if ([string]::IsNullOrWhiteSpace($CorePacDeployEnvUrl)) {
    throw "PAC_DEPLOY_CORE_ENV_URL is required. Pass -CorePacDeployEnvUrl with the Core Dev Dataverse environment URL."
}

if ([string]::IsNullOrWhiteSpace($PortalPacDeployEnvUrl)) {
    $PortalPacDeployEnvUrl = Select-PowerPlatformEnvironmentUrl `
        -Purpose "Portal Dev Dataverse environment for importing ContosoRealEstateCustomControls, ContosoRealEstateCore, and ContosoRealEstatePortal in '$GitHubEnvironmentName'" `
        -ExcludedEnvironmentUrls @($CorePacDeployEnvUrl)
}

if ([string]::IsNullOrWhiteSpace($PortalPacDeployEnvUrl)) {
    throw "PAC_DEPLOY_PORTAL_ENV_URL is required. Pass -PortalPacDeployEnvUrl with the Portal Dev Dataverse environment URL."
}

if ($CorePacDeployEnvUrl.TrimEnd('/') -eq $PortalPacDeployEnvUrl.TrimEnd('/')) {
    throw 'PAC_DEPLOY_CORE_ENV_URL and PAC_DEPLOY_PORTAL_ENV_URL must be different Dataverse environments.'
}

if ([string]::IsNullOrWhiteSpace($PortalUrl)) {
    $PortalUrl = Select-PowerPagesPortalUrl -EnvironmentUrl $PortalPacDeployEnvUrl -Purpose "Power Pages site in Portal Dev for '$GitHubEnvironmentName'"
}

$tenantId = GetRequiredValue -Name 'Azure tenant ID for PAC deployment OIDC (PAC_DEPLOY_AZURE_TENANT_ID)' -Value $PacDeployAzureTenantId
$pluginManagedIdentityAppId = GetRequiredValue -Name 'Plugin managed identity application/client ID from the Azure API deployment (PLUGIN_MANAGED_IDENTITY_APP_ID)' -Value $envVars.ENTRA_API_CLIENT_APP_ID
$spnName = "cre-github-workflows-$GitHubEnvironmentName"

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

$deploymentConfigJson = Get-DeploymentConfigurationJson -EnvironmentVariables $envVars -PortalUrl $PortalUrl -PortalPacDeployEnvUrl $PortalPacDeployEnvUrl
$existingApplicationId = $null

if ([string]::IsNullOrWhiteSpace($PacDeployClientId)) {
    $applicationIdOutput = az ad sp list --display-name $spnName --query "[0].appId" -o tsv 2>&1
    AssertCommandSucceeded -CommandDescription "Get service principal '$spnName'" -CommandOutput $applicationIdOutput
    $existingApplicationId = ($applicationIdOutput | Out-String).Trim()
}

Write-Host "Repository: $Repository" -ForegroundColor Cyan
Write-Host "GitHub deployment environment: $GitHubEnvironmentName" -ForegroundColor Cyan
Write-Host "Azure environment: $($envVars.AZURE_ENV_NAME)" -ForegroundColor Cyan
Write-Host "Core Power Platform environment URL: $CorePacDeployEnvUrl" -ForegroundColor Cyan
Write-Host "Portal Power Platform environment URL: $PortalPacDeployEnvUrl" -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($Repository, "configure GitHub deployment environment '$GitHubEnvironmentName'")) {
    $applicationId = $PacDeployClientId

    if ([string]::IsNullOrWhiteSpace($applicationId)) {
        $applicationId = $existingApplicationId
    }

    if ([string]::IsNullOrWhiteSpace($applicationId)) {
        Write-Host "Creating service principal '$spnName'." -ForegroundColor Green
        InvokeExternalCommand -CommandDescription "Create Power Platform service principal '$spnName'" -ScriptBlock {
            pac admin create-service-principal --name $spnName
        }

        $createdApplicationIdOutput = az ad sp list --display-name $spnName --query "[0].appId" -o tsv 2>&1
        AssertCommandSucceeded -CommandDescription "Get created service principal '$spnName'" -CommandOutput $createdApplicationIdOutput
        $applicationId = ($createdApplicationIdOutput | Out-String).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($applicationId)) {
        throw "Unable to determine the application ID for '$spnName'."
    }

    Set-GitHubEnvironment -Repository $Repository -EnvironmentName $GitHubEnvironmentName
    Set-GitHubEnvironmentSecret -Repository $Repository -EnvironmentName $GitHubEnvironmentName -Name 'PAC_DEPLOY_AZURE_TENANT_ID' -Value $tenantId
    Set-GitHubEnvironmentSecret -Repository $Repository -EnvironmentName $GitHubEnvironmentName -Name 'PAC_DEPLOY_CLIENT_ID' -Value $applicationId
    Set-GitHubEnvironmentSecret -Repository $Repository -EnvironmentName $GitHubEnvironmentName -Name 'PAC_DEPLOY_CORE_ENV_URL' -Value $CorePacDeployEnvUrl
    Set-GitHubEnvironmentSecret -Repository $Repository -EnvironmentName $GitHubEnvironmentName -Name 'PAC_DEPLOY_PORTAL_ENV_URL' -Value $PortalPacDeployEnvUrl
    Set-GitHubEnvironmentSecret -Repository $Repository -EnvironmentName $GitHubEnvironmentName -Name 'PLUGIN_MANAGED_IDENTITY_APP_ID' -Value $pluginManagedIdentityAppId

    $paymentsApiClientSecretInfo = Get-PaymentsApiClientSecretInfo `
        -EnvironmentVariables $envVars `
        -AzureEnv $envVars.AZURE_ENV_NAME `
        -ScriptsRoot (Join-Path -Path $repoRoot -ChildPath 'infra\scripts')
    Set-GitHubEnvironmentSecret -Repository $Repository -EnvironmentName $GitHubEnvironmentName -Name 'PAYMENTS_API_CLIENT_SECRET' -Value $paymentsApiClientSecretInfo.Value

    Set-GitHubEnvironmentVariable -Repository $Repository -EnvironmentName $GitHubEnvironmentName -Name 'PAC_DEPLOY_CONFIG' -Value $deploymentConfigJson

    Add-PowerPlatformApplicationUser -EnvironmentUrl $CorePacDeployEnvUrl -ApplicationId $applicationId -Role $PowerPlatformApplicationUserRole
    Add-PowerPlatformApplicationUser -EnvironmentUrl $PortalPacDeployEnvUrl -ApplicationId $applicationId -Role $PowerPlatformApplicationUserRole
    Add-GitHubEnvironmentFederatedCredential `
        -ApplicationId $applicationId `
        -Repository $Repository `
        -EnvironmentName $GitHubEnvironmentName `
        -CredentialName $spnName
}

Write-Host ''
Write-Host "GitHub deployment environment '$GitHubEnvironmentName' configuration complete." -ForegroundColor Green
Write-Host 'Deployment workflow: requires PAC secrets, PLUGIN_MANAGED_IDENTITY_APP_ID, PAYMENTS_API_CLIENT_SECRET, and PAC_DEPLOY_CONFIG on each deployment environment.' -ForegroundColor Green
