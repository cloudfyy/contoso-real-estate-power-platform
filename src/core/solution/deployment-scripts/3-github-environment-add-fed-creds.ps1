# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
param (
    [string]$azureEnv,
    [bool]$skipLoginChecks
)

Write-Host "This script sets up a GitHub environment federated credentials for deployment to a specific environment" -ForegroundColor White
. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv
$azureEnv = $envVars.AZURE_ENV_NAME

# Check the user is logged into AZ CLI and PAC
if (-not $skipLoginChecks) {
    CheckPACCLI
    CheckAZCLI
    CheckGitHubCLI
}

# Prompt for the name of the Github environment
$environmentName = Read-Host "Enter the name of the GitHub environment (e.g. development/test/production)"
$tenantId = az account show --query tenantId -o tsv
$environmentUrl = Get-PowerPlatformEnvironmentUrl
$spnName = "cre-github-workflows-$environmentName"
Set-Location -Path $PSScriptRoot
$repoName = GetGitHubRepositoryName -remoteNames @('origin')


if (-not (ConfirmPrompt -message "Are you sure you want to create federated credentials for GitHub '$environmentName' in the repo '$repoName' for the environment '$environmentUrl' ?")) {
    Write-Host "Exiting" -ForegroundColor Yellow
    exit
}

# Check if the spn already exist
$applicationId = az ad sp list --display-name $spnName --query "[0].appId" -o tsv

if ($applicationId)
{
    Write-Host "Adding existing SPN '$spnName' and adding to '$environmentUrl'" -ForegroundColor Green
    Add-PowerPlatformApplicationUser -EnvironmentUrl $environmentUrl -ApplicationId $applicationId -Role 'System Administrator'
}
else
{
    Write-Host "Creating SPN '$spnName' and adding to '$environmentUrl'" -ForegroundColor Green
    pac admin create-service-principal --name $spnName
    # Currently the pac admin create-service-principal or list-service-principal verbs do not support the --json command, so use az to get the application id
    $applicationId = az ad sp list --display-name $spnName --query "[0].appId" -o tsv
}

Write-Host "Adding federated credentials to $applicationId for environment $environmentName and repo $repoName" -ForegroundColor Green
Add-GitHubEnvironmentFederatedCredential `
    -ApplicationId $applicationId `
    -Repository $repoName `
    -EnvironmentName $environmentName `
    -CredentialName $spnName

Write-Host "Configuring GitHub environment '$environmentName' in '$repoName'" -ForegroundColor Green
Set-GitHubEnvironment -Repository $repoName -EnvironmentName $environmentName
Set-GitHubEnvironmentSecret -Repository $repoName -EnvironmentName $environmentName -Name 'PAC_DEPLOY_AZURE_TENANT_ID' -Value $tenantId
Set-GitHubEnvironmentSecret -Repository $repoName -EnvironmentName $environmentName -Name 'PAC_DEPLOY_CLIENT_ID' -Value $applicationId
Set-GitHubEnvironmentSecret -Repository $repoName -EnvironmentName $environmentName -Name 'PAC_DEPLOY_ENV_URL' -Value $environmentUrl

Write-Host "Adding Key Vault access to the SPN so that Key Vault Environment Variables in Dataverse can be read" -ForegroundColor Green
# This prevents the solution import error 'The reason given was: User is not authorized to read secrets from '/subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/..../secrets/...-development-payments-api-client-secret' resource.
az role assignment create --role "Key Vault Secrets User" --assignee $applicationId --scope /subscriptions/$($envVars.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($envVars.AZURE_RESOURCE_GROUP)/providers/Microsoft.KeyVault/vaults/$($envVars.AZURE_KEY_VAULT_NAME) >> $null
az role assignment create --role "Key Vault Reader" --assignee $applicationId --scope /subscriptions/$($envVars.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($envVars.AZURE_RESOURCE_GROUP)/providers/Microsoft.KeyVault/vaults/$($envVars.AZURE_KEY_VAULT_NAME) >> $null

Write-Host @"
GitHub environment '$environmentName' has been configured in '$repoName' with these PAC deployment secrets:

    PAC_DEPLOY_AZURE_TENANT_ID
    PAC_DEPLOY_CLIENT_ID
    PAC_DEPLOY_ENV_URL
"@ -ForegroundColor Cyan