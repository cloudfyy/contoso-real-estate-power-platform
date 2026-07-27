# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script validates payments SQL and Key Vault configuration through the Payments API Function App.
# -----------------------------------------------------------------------
param (
    [string]$azureEnv
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\payments-api-function-helpers.ps1"

function Invoke-ValidationEndpointWithRetry {
    param (
        [string]$Uri,
        [string]$Token
    )

    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            return Invoke-RestMethod `
                -Method Get `
                -Uri $Uri `
                -Headers @{ Authorization = "Bearer $Token" }
        }
        catch {
            $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -notin @(401, 404, 502, 503, 504)) {
                $responseBody = $_.ErrorDetails.Message
                if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                    try {
                        $errorResult = $responseBody | ConvertFrom-Json
                        Write-Host "Validation endpoint returned status ${statusCode}: $($errorResult.message)" -ForegroundColor Red
                        Write-Host "Error: $($errorResult.error)" -ForegroundColor Red
                        Write-Host "Error type: $($errorResult.errorType)" -ForegroundColor Red
                    }
                    catch {
                        Write-Host "Validation endpoint returned status ${statusCode}: $responseBody" -ForegroundColor Red
                    }

                    if ($responseBody -like '*Login failed for user*token-identified principal*') {
                        Write-Host "SQL rejected the Function App managed identity. Run initialize-sql-via-function.ps1, or verify the SQL connection string points to the initialized payments database." -ForegroundColor Yellow
                    }
                }

                throw
            }

            $responseBody = $_.ErrorDetails.Message
            if ([string]::IsNullOrWhiteSpace($responseBody)) {
                Write-Host "Validation endpoint not ready yet (attempt $attempt/60, status $statusCode)." -ForegroundColor Yellow
            }
            else {
                Write-Host "Validation endpoint not ready yet (attempt $attempt/60, status $statusCode): $responseBody" -ForegroundColor Yellow
            }
        }

        Start-Sleep -Seconds 5
    }

    throw "The Function App did not return validation data from '$Uri'. Authenticated calls kept returning a transient or disabled response."
}

. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv
$selectedAzureEnv = Get-RequiredValue $envVars.AZURE_ENV_NAME 'AZURE_ENV_NAME'

$functionAppName = Get-RequiredValue $envVars.SERVICE_API_NAME 'SERVICE_API_NAME'
$functionAppUri = Get-RequiredValue $envVars.SERVICE_API_URI 'SERVICE_API_URI'
$resourceGroupName = Get-RequiredValue $envVars.AZURE_RESOURCE_GROUP 'AZURE_RESOURCE_GROUP'
$apiAppId = Get-RequiredValue $envVars.ENTRA_API_APP_ID 'ENTRA_API_APP_ID'
$apiClientAppId = Get-RequiredValue $envVars.ENTRA_API_CLIENT_APP_ID 'ENTRA_API_CLIENT_APP_ID'
$apiClientObjectId = Get-RequiredValue $envVars.ENTRA_API_CLIENT_OBJECT_ID 'ENTRA_API_CLIENT_OBJECT_ID'
$tenantId = Get-RequiredValue $envVars.AZURE_TENANT_ID 'AZURE_TENANT_ID'

Write-Host "Ensuring the current user has the Payments API configuration validation role" -ForegroundColor Green
& "$PSScriptRoot\grant-access-to-payment-api.ps1" -azureEnv $selectedAzureEnv

$apiClientSecret = az functionapp config appsettings list `
    --resource-group $resourceGroupName `
    --name $functionAppName `
    --query "[?name=='PAYMENTS_API_CLIENT_SECRET'].value | [0]" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($apiClientSecret)) {
    throw "Could not read PAYMENTS_API_CLIENT_SECRET from Function App '$functionAppName'. Run azd provision, or run infra/scripts/generate-payments-api-client-secret.ps1 if the configured client secret is missing or invalid."
}

try {
    $token = Get-PaymentsApiAccessTokenWithRole `
        -TenantId $tenantId `
        -ApiAppId $apiAppId `
        -ApiClientAppId $apiClientAppId `
        -ApiClientSecret $apiClientSecret `
        -RequiredRole 'CanValidatePaymentsConfiguration'
}
catch {
    if ($_.ErrorDetails.Message -notlike '*invalid_client*') {
        throw
    }

    throw "The configured PAYMENTS_API_CLIENT_SECRET is invalid. Run infra/scripts/generate-payments-api-client-secret.ps1 to generate a new client secret, then rerun this script."
}

if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Could not acquire an application access token for api://$apiAppId. Ensure the client app has the CanValidatePaymentsConfiguration application role and admin consent."
}

$secretReadToken = Get-PaymentsApiAccessTokenWithRole `
    -TenantId $tenantId `
    -ApiAppId $apiAppId `
    -ApiClientAppId $apiClientAppId `
    -ApiClientSecret $apiClientSecret `
    -RequiredRole 'CanReadPaymentsApiClientSecret'

if ([string]::IsNullOrWhiteSpace($secretReadToken)) {
    throw "Could not acquire an application access token for api://$apiAppId. Ensure the client app has the CanReadPaymentsApiClientSecret application role and admin consent."
}

try {
    Write-Host "Waiting for the Function App to apply configuration validation settings" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings CONFIGURATION_VALIDATION_ENABLED=true PAYMENTS_API_CLIENT_SECRET_READ_ENABLED=true `
        --output none

    Wait-FunctionAppSetting `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -Name 'CONFIGURATION_VALIDATION_ENABLED' `
        -ExpectedValue 'true'

    Wait-FunctionAppSetting `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -Name 'PAYMENTS_API_CLIENT_SECRET_READ_ENABLED' `
        -ExpectedValue 'true'

    Restart-FunctionAppAndWait `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -FunctionAppUri $functionAppUri

    $sqlValidationUri = "$($functionAppUri.TrimEnd('/'))/api/configuration/validate-sql"
    $keyVaultValidationUri = "$($functionAppUri.TrimEnd('/'))/api/configuration/validate-key-vault"
    $paymentsApiClientSecretUri = "$($functionAppUri.TrimEnd('/'))/api/configuration/payments-api-client-secret"

    Write-Host "Calling $sqlValidationUri" -ForegroundColor Green
    $sqlValidation = Invoke-ValidationEndpointWithRetry -Uri $sqlValidationUri -Token $token
    Write-Host "SQL validation result" -ForegroundColor Cyan
    $sqlValidation | ConvertTo-Json -Depth 20

    Write-Host "Calling $keyVaultValidationUri" -ForegroundColor Green
    $keyVaultValidation = Invoke-ValidationEndpointWithRetry -Uri $keyVaultValidationUri -Token $token
    Write-Host "Key Vault validation result" -ForegroundColor Cyan
    $keyVaultValidation | ConvertTo-Json -Depth 20

    Write-Host "Calling $paymentsApiClientSecretUri" -ForegroundColor Green
    $paymentsApiClientSecret = Invoke-ValidationEndpointWithRetry -Uri $paymentsApiClientSecretUri -Token $secretReadToken
    if ([string]::IsNullOrWhiteSpace($paymentsApiClientSecret.value)) {
        throw "The Payments API client secret endpoint did not return a secret value."
    }

    Write-Host "Payments API client secret endpoint result" -ForegroundColor Cyan
    @{
        name = $paymentsApiClientSecret.name
        valueLength = ([string]$paymentsApiClientSecret.value).Length
    } | ConvertTo-Json
}
finally {
    Write-Host "Disabling the configuration validation endpoints" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings CONFIGURATION_VALIDATION_ENABLED=false PAYMENTS_API_CLIENT_SECRET_READ_ENABLED=false `
        --output none

    Restart-FunctionAppAndWait `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -FunctionAppUri $functionAppUri
}

Write-Host "Payments configuration validation complete." -ForegroundColor Green