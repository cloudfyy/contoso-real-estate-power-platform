# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script displays the Payments API client secret through the Payments API Function App for manual custom connector setup.
# -----------------------------------------------------------------------
param (
    [string]$azureEnv
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\payments-api-function-helpers.ps1"

function Invoke-PaymentsApiClientSecretEndpointWithRetry {
    param (
        [string]$Uri,
        [string]$Token
    )

    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            return Invoke-RestMethod `
                -Method Get `
                -Uri $Uri `
                -Headers @{ Authorization = "Bearer $Token"; Accept = 'application/json' } `
                -ContentType 'application/json'
        }
        catch {
            $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -notin @(401, 403, 404, 502, 503, 504)) {
                throw
            }

            $responseBody = $_.ErrorDetails.Message
            if ([string]::IsNullOrWhiteSpace($responseBody)) {
                Write-Host "Payments API client secret endpoint not ready yet (attempt $attempt/60, status $statusCode)." -ForegroundColor Yellow
            }
            else {
                Write-Host "Payments API client secret endpoint not ready yet (attempt $attempt/60, status $statusCode): $responseBody" -ForegroundColor Yellow
            }
        }

        Start-Sleep -Seconds 5
    }

    throw "The Function App did not return the Payments API client secret from '$Uri'. Authenticated calls kept returning a transient or disabled response."
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

Write-Host "Ensuring the current user has the Payments API client secret read role" -ForegroundColor Green
& "$PSScriptRoot\grant-access-to-payment-api.ps1" -azureEnv $selectedAzureEnv

$apiClientSecret = az functionapp config appsettings list `
    --resource-group $resourceGroupName `
    --name $functionAppName `
    --query "[?name=='PAYMENTS_API_CLIENT_SECRET'].value | [0]" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($apiClientSecret)) {
    throw "Could not read PAYMENTS_API_CLIENT_SECRET from Function App '$functionAppName'. Run azd provision, or run infra/scripts/repair-payments-api-easyauth-secret.ps1 if the configured client secret is invalid."
}

try {
    $token = Get-PaymentsApiAccessTokenWithRole `
        -TenantId $tenantId `
        -ApiAppId $apiAppId `
        -ApiClientAppId $apiClientAppId `
        -ApiClientSecret $apiClientSecret `
        -RequiredRole 'CanReadPaymentsApiClientSecret'
}
catch {
    if ($_.ErrorDetails.Message -notlike '*invalid_client*') {
        throw
    }

    throw "The configured PAYMENTS_API_CLIENT_SECRET is invalid. Run infra/scripts/repair-payments-api-easyauth-secret.ps1 to repair the client secret, then rerun this script."
}

try {
    Write-Host "Temporarily enabling the Payments API client secret read endpoint" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings PAYMENTS_API_CLIENT_SECRET_READ_ENABLED=true `
        --output none

    Wait-FunctionAppSetting `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -Name 'PAYMENTS_API_CLIENT_SECRET_READ_ENABLED' `
        -ExpectedValue 'true'

    Restart-FunctionAppAndWait `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -FunctionAppUri $functionAppUri

    $secretReadUri = "$($functionAppUri.TrimEnd('/'))/api/configuration/payments-api-client-secret"
    $secretResponse = Invoke-PaymentsApiClientSecretEndpointWithRetry `
        -Uri $secretReadUri `
        -Token $token

    if ([string]::IsNullOrWhiteSpace($secretResponse.value)) {
        throw "The Payments API client secret endpoint did not return a secret value."
    }

    if ([string]::IsNullOrWhiteSpace([string]$secretResponse.name)) {
        throw "The Payments API client secret endpoint did not return the secret name."
    }

    $secretExpiresOn = if ($null -ne $secretResponse.expiresOn -and -not [string]::IsNullOrWhiteSpace([string]$secretResponse.expiresOn)) {
        [string]$secretResponse.expiresOn
    }
    else {
        '<not set>'
    }

    Write-Host "Use the following values when editing the Contoso Payments API and Contoso Stripe API custom connectors:" -ForegroundColor Green
    Write-Host "Client ID:" -ForegroundColor Green
    Write-Host $apiClientAppId -ForegroundColor Cyan
    Write-Host "Key Vault Secret Name:" -ForegroundColor Green
    Write-Host ([string]$secretResponse.name) -ForegroundColor Cyan
    Write-Host "Key Vault Secret ExpiresOn:" -ForegroundColor Green
    Write-Host $secretExpiresOn -ForegroundColor Cyan
    Write-Host "Client Secret:" -ForegroundColor Green
    Write-Host ([string]$secretResponse.value) -ForegroundColor Cyan
}
finally {
    Write-Host "Disabling the Payments API client secret read endpoint" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings PAYMENTS_API_CLIENT_SECRET_READ_ENABLED=false `
        --output none

    Restart-FunctionAppAndWait `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -FunctionAppUri $functionAppUri
}
