# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [string]$azureEnv,
    [string]$Repository,
    [string]$Remote = 'origin',
    [string]$SolutionCheckerEnvironment = 'solution-checker',
    [string]$PacDeployAzureTenantId,
    [string]$PacDeployClientId,
    [string]$PacDeployEnvUrl,
    [string]$SolutionsConfigPath,
    [switch]$SkipSolutionCheckerSecrets
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\solution-packages.ps1"
. "$PSScriptRoot\common\environment-variables.ps1"

$repoRoot = Get-RepositoryRoot
Set-Location -Path $repoRoot

AssertCommandExists -Name 'git'
AssertCommandExists -Name 'az'

CheckGitHubCLI
CheckAZCLI

if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = GetGitHubRepositoryName -remoteNames @($Remote)
}

$envVars = GetRepositoryEnvironmentVariables -azureEnv $azureEnv -scriptDirectory $repoRoot

if ([string]::IsNullOrWhiteSpace($PacDeployAzureTenantId) -and -not [string]::IsNullOrWhiteSpace($envVars.AZURE_TENANT_ID)) {
    $PacDeployAzureTenantId = $envVars.AZURE_TENANT_ID
}

if ([string]::IsNullOrWhiteSpace($PacDeployClientId) -and -not [string]::IsNullOrWhiteSpace($envVars.ENTRA_API_CLIENT_APP_ID)) {
    $PacDeployClientId = $envVars.ENTRA_API_CLIENT_APP_ID
}

if ([string]::IsNullOrWhiteSpace($PacDeployEnvUrl)) {
    $PacDeployEnvUrl = Get-PowerPlatformEnvironmentUrl
}

if (-not [string]::IsNullOrWhiteSpace($SolutionsConfigPath)) {
    $solutionsConfigJson = Get-Content -Path $SolutionsConfigPath -Raw
}
else {
    $solutionsConfigJson = Get-GitHubSolutionsConfigJson
}

$null = $solutionsConfigJson | ConvertFrom-Json

Write-Host "Repository: $Repository" -ForegroundColor Cyan
Write-Host "Solution checker environment: $SolutionCheckerEnvironment" -ForegroundColor Cyan
Write-Host "Azure environment: $($envVars.AZURE_ENV_NAME)" -ForegroundColor Cyan

$tenantId = $null
$clientId = $null
$environmentUrl = $null

if (-not $SkipSolutionCheckerSecrets) {
    $tenantId = GetRequiredValue -Name 'PAC_DEPLOY_AZURE_TENANT_ID' -Value $PacDeployAzureTenantId
    $clientId = GetRequiredValue -Name 'PAC_DEPLOY_CLIENT_ID' -Value $PacDeployClientId
    $environmentUrl = GetRequiredValue -Name 'PAC_DEPLOY_ENV_URL' -Value $PacDeployEnvUrl
}
elseif (-not [string]::IsNullOrWhiteSpace($PacDeployClientId)) {
    $clientId = $PacDeployClientId
}

if ($PSCmdlet.ShouldProcess($Repository, 'configure GitHub Build and Validate prerequisites')) {
    Set-GitHubEnvironment -Repository $Repository -EnvironmentName $SolutionCheckerEnvironment
    Set-GitHubRepositoryVariable -Repository $Repository -Name 'SOLUTIONS_CONFIG' -Value $solutionsConfigJson

    if (-not $SkipSolutionCheckerSecrets) {
        Set-GitHubEnvironmentSecret -Repository $Repository -EnvironmentName $SolutionCheckerEnvironment -Name 'PAC_DEPLOY_AZURE_TENANT_ID' -Value $tenantId
        Set-GitHubEnvironmentSecret -Repository $Repository -EnvironmentName $SolutionCheckerEnvironment -Name 'PAC_DEPLOY_CLIENT_ID' -Value $clientId
        Set-GitHubEnvironmentSecret -Repository $Repository -EnvironmentName $SolutionCheckerEnvironment -Name 'PAC_DEPLOY_ENV_URL' -Value $environmentUrl
    }

    if (-not [string]::IsNullOrWhiteSpace($clientId)) {
        Add-GitHubEnvironmentFederatedCredential `
            -ApplicationId $clientId `
            -Repository $Repository `
            -EnvironmentName $SolutionCheckerEnvironment
    }
    else {
        Write-Host "Skipping federated credential setup because PAC_DEPLOY_CLIENT_ID is not available." -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Build/Validate GitHub configuration complete.' -ForegroundColor Green
Write-Host 'Validate workflow: no additional repository variables or secrets are required.' -ForegroundColor Green
Write-Host 'Build workflow: requires SOLUTIONS_CONFIG plus PAC secrets in the solution-checker environment.' -ForegroundColor Green
Write-Host "Build workflow: the PAC client application must have GitHub federated credentials for the '$SolutionCheckerEnvironment' environment." -ForegroundColor Green
