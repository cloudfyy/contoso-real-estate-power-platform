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

function Get-PowerPlatformEnvironmentUrl {
    if (-not (Get-Command 'pac' -ErrorAction SilentlyContinue)) {
        return ''
    }

    $environmentDetailsJson = pac env who --json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($environmentDetailsJson -join ''))) {
        return ''
    }

    $environmentDetails = $environmentDetailsJson | ConvertFrom-Json
    return ([string]$environmentDetails.OrgUrl).TrimEnd('/')
}

$repoRoot = Get-RepositoryRoot
Set-Location -Path $repoRoot

AssertCommandExists -Name 'git'
AssertCommandExists -Name 'gh'

InvokeExternalCommand -CommandDescription 'Check GitHub CLI authentication' -ScriptBlock {
    gh auth status --hostname github.com
}

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

if ($PSCmdlet.ShouldProcess($Repository, 'configure GitHub Build and Validate prerequisites')) {
    InvokeExternalCommand -CommandDescription "Create or update GitHub environment '$SolutionCheckerEnvironment'" -ScriptBlock {
        gh api --method PUT "repos/$Repository/environments/$SolutionCheckerEnvironment" --silent
    }

    InvokeExternalCommand -CommandDescription "Set repository variable 'SOLUTIONS_CONFIG'" -ScriptBlock {
        gh variable set SOLUTIONS_CONFIG --repo $Repository --body $solutionsConfigJson
    }

    if (-not $SkipSolutionCheckerSecrets) {
        $tenantId = GetRequiredValue -Name 'PAC_DEPLOY_AZURE_TENANT_ID' -Value $PacDeployAzureTenantId
        $clientId = GetRequiredValue -Name 'PAC_DEPLOY_CLIENT_ID' -Value $PacDeployClientId
        $environmentUrl = GetRequiredValue -Name 'PAC_DEPLOY_ENV_URL' -Value $PacDeployEnvUrl

        InvokeExternalCommand -CommandDescription "Set environment secret 'PAC_DEPLOY_AZURE_TENANT_ID'" -ScriptBlock {
            $tenantId | gh secret set PAC_DEPLOY_AZURE_TENANT_ID --repo $Repository --env $SolutionCheckerEnvironment
        }

        InvokeExternalCommand -CommandDescription "Set environment secret 'PAC_DEPLOY_CLIENT_ID'" -ScriptBlock {
            $clientId | gh secret set PAC_DEPLOY_CLIENT_ID --repo $Repository --env $SolutionCheckerEnvironment
        }

        InvokeExternalCommand -CommandDescription "Set environment secret 'PAC_DEPLOY_ENV_URL'" -ScriptBlock {
            $environmentUrl | gh secret set PAC_DEPLOY_ENV_URL --repo $Repository --env $SolutionCheckerEnvironment
        }
    }
}

Write-Host ''
Write-Host 'Build/Validate GitHub configuration complete.' -ForegroundColor Green
Write-Host 'Validate workflow: no additional repository variables or secrets are required.' -ForegroundColor Green
Write-Host 'Build workflow: requires SOLUTIONS_CONFIG plus PAC secrets in the solution-checker environment.' -ForegroundColor Green
Write-Host 'The PAC client application must also have a GitHub federated credential for repo:<owner>/<repo>:environment:solution-checker.' -ForegroundColor Yellow