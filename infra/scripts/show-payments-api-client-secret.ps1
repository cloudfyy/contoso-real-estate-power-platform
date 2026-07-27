# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script displays the Payments API client secret through the Payments API Function App for manual custom connector setup.
# -----------------------------------------------------------------------
param (
    [string]$azureEnv
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\payments-api-function-helpers.ps1"
. "$PSScriptRoot\common\payments-api-client-secret.ps1"

. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv
$selectedAzureEnv = Get-RequiredValue $envVars.AZURE_ENV_NAME 'AZURE_ENV_NAME'

$secretInfo = Get-PaymentsApiClientSecretInfo `
    -EnvironmentVariables $envVars `
    -AzureEnv $selectedAzureEnv `
    -ScriptsRoot $PSScriptRoot

$secretExpiresOn = if (-not [string]::IsNullOrWhiteSpace($secretInfo.ExpiresOn)) {
    $secretInfo.ExpiresOn
}
else {
    '<not set>'
}

Write-Host "Use the following values when editing the Contoso Payments API and Contoso Stripe API custom connectors:" -ForegroundColor Green
Write-Host "Client ID:" -ForegroundColor Green
Write-Host $secretInfo.ClientId -ForegroundColor Cyan
Write-Host "Key Vault Secret Name:" -ForegroundColor Green
Write-Host $secretInfo.Name -ForegroundColor Cyan
Write-Host "Key Vault Secret ExpiresOn:" -ForegroundColor Green
Write-Host $secretExpiresOn -ForegroundColor Cyan
Write-Host "Client Secret:" -ForegroundColor Green
Write-Host $secretInfo.Value -ForegroundColor Cyan
