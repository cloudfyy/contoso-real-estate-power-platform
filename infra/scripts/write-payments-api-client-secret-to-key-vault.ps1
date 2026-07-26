# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script writes the Payments API client secret to Key Vault through the deployed Payments API Function App.
# -----------------------------------------------------------------------
param (
    [string]$azureEnv
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\payments-api-function-helpers.ps1"

function Invoke-PaymentsApiClientSecretWriteWithRetry {
    param (
        [string]$Uri,
        [string]$Token,
        [string]$SecretValue
    )

    $requestBody = @{
        value = $SecretValue
    } | ConvertTo-Json -Compress

    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            return Invoke-RestMethod `
                -Method Post `
                -Uri $Uri `
                -Headers @{ Authorization = "Bearer $Token" } `
                -ContentType 'application/json' `
                -Body $requestBody
        }
        catch {
            $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -notin @(404, 502, 503, 504)) {
                $responseBody = $_.ErrorDetails.Message
                if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                    try {
                        $errorResult = $responseBody | ConvertFrom-Json
                        Write-Host "Secret write endpoint returned status ${statusCode}: $($errorResult.message)" -ForegroundColor Red
                        Write-Host "Error: $($errorResult.error)" -ForegroundColor Red
                        Write-Host "Error type: $($errorResult.errorType)" -ForegroundColor Red
                    }
                    catch {
                        Write-Host "Secret write endpoint returned status ${statusCode}: $responseBody" -ForegroundColor Red
                    }
                }

                throw
            }

            $responseBody = $_.ErrorDetails.Message
            if ([string]::IsNullOrWhiteSpace($responseBody)) {
                Write-Host "Secret write endpoint not ready yet (attempt $attempt/60, status $statusCode)." -ForegroundColor Yellow
            }
            else {
                Write-Host "Secret write endpoint not ready yet (attempt $attempt/60, status $statusCode): $responseBody" -ForegroundColor Yellow
            }
        }

        Start-Sleep -Seconds 5
    }

    throw "The Function App did not apply Payments API client secret write settings. Authenticated calls to '$Uri' kept returning a transient or disabled response."
}

. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv
$selectedAzureEnv = Get-RequiredValue $envVars.AZURE_ENV_NAME 'AZURE_ENV_NAME'

$functionAppName = Get-RequiredValue $envVars.SERVICE_API_NAME 'SERVICE_API_NAME'
$functionAppUri = Get-RequiredValue $envVars.SERVICE_API_URI 'SERVICE_API_URI'
$resourceGroupName = Get-RequiredValue $envVars.AZURE_RESOURCE_GROUP 'AZURE_RESOURCE_GROUP'
$apiAppId = Get-RequiredValue $envVars.ENTRA_API_APP_ID 'ENTRA_API_APP_ID'
$apiClientAppId = Get-RequiredValue $envVars.ENTRA_API_CLIENT_APP_ID 'ENTRA_API_CLIENT_APP_ID'
$tenantId = Get-RequiredValue $envVars.AZURE_TENANT_ID 'AZURE_TENANT_ID'
$secretName = Get-RequiredValue $envVars.AZURE_KEY_VAULT_ENTRA_API_SECRET_NAME 'AZURE_KEY_VAULT_ENTRA_API_SECRET_NAME'

Write-Host "Ensuring the current user has the Payments API client secret write role" -ForegroundColor Green
& "$PSScriptRoot\grant-access-to-payment-api.ps1" -azureEnv $selectedAzureEnv

$apiClientSecret = az functionapp config appsettings list `
    --resource-group $resourceGroupName `
    --name $functionAppName `
    --query "[?name=='PAYMENTS_API_CLIENT_SECRET'].value | [0]" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($apiClientSecret)) {
    throw "Could not read PAYMENTS_API_CLIENT_SECRET from Function App '$functionAppName'. Run azd provision first."
}

$token = Get-PaymentsApiAccessTokenWithRole `
    -TenantId $tenantId `
    -ApiAppId $apiAppId `
    -ApiClientAppId $apiClientAppId `
    -ApiClientSecret $apiClientSecret `
    -RequiredRole 'CanWritePaymentsApiClientSecret' `
    -RetryCount 120

try {
    Write-Host "Waiting for the Function App to apply Payments API client secret write settings" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings PAYMENTS_API_CLIENT_SECRET_WRITE_ENABLED=true `
        --output none

    Wait-FunctionAppSetting `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -Name 'PAYMENTS_API_CLIENT_SECRET_WRITE_ENABLED' `
        -ExpectedValue 'true'

    Restart-FunctionAppAndWait `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -FunctionAppUri $functionAppUri

    $secretWriteUri = "$($functionAppUri.TrimEnd('/'))/api/configuration/payments-api-client-secret"
    Write-Host "Calling $secretWriteUri to store Key Vault secret '$secretName'" -ForegroundColor Green
    $result = Invoke-PaymentsApiClientSecretWriteWithRetry `
        -Uri $secretWriteUri `
        -Token $token `
        -SecretValue $apiClientSecret

    Write-Host "Payments API client secret stored in Key Vault" -ForegroundColor Cyan
    @{
        name = $result.name
        updatedOn = $result.updatedOn
    } | ConvertTo-Json
}
finally {
    Write-Host "Disabling the Payments API client secret write endpoint" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings PAYMENTS_API_CLIENT_SECRET_WRITE_ENABLED=false `
        --output none

    Restart-FunctionAppAndWait `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -FunctionAppUri $functionAppUri
}

Write-Host "Payments API client secret Key Vault write complete." -ForegroundColor Green
