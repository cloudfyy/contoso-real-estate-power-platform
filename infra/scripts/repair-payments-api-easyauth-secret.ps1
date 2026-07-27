# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script repairs the Function App EasyAuth secret used by the Payments API app registration.
# -----------------------------------------------------------------------
param (
    [string]$azureEnv,
    [switch]$SkipRestart
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\payments-api-function-helpers.ps1"
. "$PSScriptRoot\function-get-environment-variables.ps1"

$envVars = GetEnvironmentVariables -azureEnv $azureEnv

$functionAppName = Get-RequiredValue $envVars.SERVICE_API_NAME 'SERVICE_API_NAME'
$resourceGroupName = Get-RequiredValue $envVars.AZURE_RESOURCE_GROUP 'AZURE_RESOURCE_GROUP'
$tenantId = Get-RequiredValue $envVars.AZURE_TENANT_ID 'AZURE_TENANT_ID'
$apiAppId = Get-RequiredValue $envVars.ENTRA_API_APP_ID 'ENTRA_API_APP_ID'
$apiObjectId = Get-RequiredValue $envVars.ENTRA_API_OBJECT_ID 'ENTRA_API_OBJECT_ID'

$credentialDisplayName = 'Client Secret for EasyAuth'
$existingEasyAuthSecret = Get-FunctionAppSetting `
    -ResourceGroupName $resourceGroupName `
    -FunctionAppName $functionAppName `
    -Name 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'

if (Test-EasyAuthClientSecret -TenantId $tenantId -ApiAppId $apiAppId -ClientSecret $existingEasyAuthSecret) {
    Write-Host 'Existing EasyAuth client secret is still valid. Skipping EasyAuth secret generation.' -ForegroundColor Green
    return
}

$easyAuthCredential = New-EntraClientSecret `
    -ApplicationObjectId $apiObjectId `
    -DisplayName $credentialDisplayName `
    -TenantId $tenantId

Write-Host 'Updating Function App EasyAuth secret setting' -ForegroundColor Yellow
az functionapp config appsettings set `
    --resource-group $resourceGroupName `
    --name $functionAppName `
    --settings "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=$($easyAuthCredential.SecretText)" `
    --output none

Wait-FunctionAppSetting `
    -ResourceGroupName $resourceGroupName `
    -FunctionAppName $functionAppName `
    -Name 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET' `
    -ExpectedValue $easyAuthCredential.SecretText `
    -RedactValue

if (-not (Test-EasyAuthClientSecret -TenantId $tenantId -ApiAppId $apiAppId -ClientSecret $easyAuthCredential.SecretText)) {
    throw 'The repaired EasyAuth secret did not validate against the Payments API app registration.'
}

Remove-PreviousEntraClientSecrets `
    -ApplicationId $apiAppId `
    -DisplayName $credentialDisplayName `
    -CurrentKeyId $easyAuthCredential.KeyId

if ($SkipRestart) {
    Write-Host 'Skipping Function App restart because -SkipRestart was provided.' -ForegroundColor Yellow
}
else {
    Write-Host "Restarting Function App '$functionAppName'" -ForegroundColor Yellow
    az functionapp restart `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --output none
}

Write-Host 'Payments API EasyAuth secret repair complete.' -ForegroundColor Green
