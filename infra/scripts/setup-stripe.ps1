# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script sets up the stripe payment keys
# -----------------------------------------------------------------------
param (
    [string]$azureEnv
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\payments-api-function-helpers.ps1"

function Get-StripeWebhookFunctionKey {
    param (
        [string]$ResourceGroupName,
        [string]$FunctionAppName,
        [string]$FunctionName
    )

    $functionKey = az functionapp function keys list `
        --function-name $FunctionName `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --query "default" `
        --output tsv

    if (![string]::IsNullOrWhiteSpace($functionKey)) {
        return $functionKey
    }

    Write-Host "Function-specific key for '$FunctionName' was not found. Falling back to the Function App default host key." -ForegroundColor Yellow
    $hostKey = az functionapp keys list `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --query "functionKeys.default" `
        --output tsv

    if (![string]::IsNullOrWhiteSpace($hostKey)) {
        return $hostKey
    }

    throw "Could not retrieve a Function key for '$FunctionName' in Function App '$FunctionAppName'. Deploy the Function App and ensure the '$FunctionName' function exists before running this script."
}

function Invoke-StripeConfigurationWithRetry {
    param (
        [string]$Uri,
        [string]$Token,
        [string]$StripeApiKey,
        [string]$StripeWebhookSecret
    )

    $requestBody = @{
        stripeApiKey = $StripeApiKey
        stripeWebhookSecret = $StripeWebhookSecret
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
                throw
            }

            $responseBody = $_.ErrorDetails.Message
            if ([string]::IsNullOrWhiteSpace($responseBody)) {
                Write-Host "Stripe configuration endpoint not ready yet (attempt $attempt/60, status $statusCode)." -ForegroundColor Yellow
            }
            else {
                Write-Host "Stripe configuration endpoint not ready yet (attempt $attempt/60, status $statusCode): $responseBody" -ForegroundColor Yellow
            }
        }

        Start-Sleep -Seconds 5
    }

    throw "The Function App did not apply Stripe configuration. Authenticated calls to '$Uri' kept returning a transient or disabled response."
}

# -----------------------------------------------------------------------
# Import the environment variables
. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv

$functionAppName = Get-RequiredValue $envVars.SERVICE_API_NAME 'SERVICE_API_NAME'
$functionAppUri = Get-RequiredValue $envVars.SERVICE_API_URI 'SERVICE_API_URI'
$functionName = "StripeWebhook"
$resourceGroupName = Get-RequiredValue $envVars.AZURE_RESOURCE_GROUP 'AZURE_RESOURCE_GROUP'
$apiAppId = Get-RequiredValue $envVars.ENTRA_API_APP_ID 'ENTRA_API_APP_ID'
$apiClientAppId = Get-RequiredValue $envVars.ENTRA_API_CLIENT_APP_ID 'ENTRA_API_CLIENT_APP_ID'
$apiClientObjectId = Get-RequiredValue $envVars.ENTRA_API_CLIENT_OBJECT_ID 'ENTRA_API_CLIENT_OBJECT_ID'
$tenantId = Get-RequiredValue $envVars.AZURE_TENANT_ID 'AZURE_TENANT_ID'
$selectedAzureEnv = Get-RequiredValue $envVars.AZURE_ENV_NAME 'AZURE_ENV_NAME'

Write-Host "Ensuring the current user has the Payments API Stripe configuration role" -ForegroundColor Green
& "$PSScriptRoot\grant-access-to-payment-api.ps1" -azureEnv $selectedAzureEnv

Write-Host "Configuring Stripe through the Payments API Function App" -ForegroundColor White

# Prompt for the Stripe Webhook Secret
Write-Host @"
Locate the Stripe API Key in your Stripe account by:
1. Logging into your Stripe account
2. Navigating to the Developers-> API Keys section https://dashboard.stripe.com/test/apikeys
3. Copy the 'Secret key' by clicking on it, and enter it below

"@ -ForegroundColor Cyan
$stripeApiKey = Read-Host -Prompt "Please enter the Stripe API Key (Right click to paste)"

# Get the Function Key
$functionKey = Get-StripeWebhookFunctionKey `
    -ResourceGroupName $resourceGroupName `
    -FunctionAppName $functionAppName `
    -FunctionName $functionName
# Construct the Full URL
$functionUrl="$($functionAppUri.TrimEnd('/'))/api/stripe/webhook?code=$($functionKey)"

Write-Host @"
Register a new webhook endpoint in your Stripe account:

You can do this by:
1. Logging into your Stripe account
2. Navigating to the Developers -> Webhooks section https://dashboard.stripe.com/test/workbench/webhooks
4. Select '+ Add destination'
5. Select Checkout -> Select all Checkout events.
6. Select Continue -> Webhook endpoint -> Continue
7. Entering the following URL in the 'Endpoint URL' field
    $functionUrl
8. Keep this URL private because it includes the Function key.
9. Select on 'Create destination'
10. Select Reveal next to the Signing secret.
11. Copy the 'Signing secret' by selecting the clip board icon, and enter it below

"@ -ForegroundColor Cyan

# Prompt for the Stripe API Key
$stripeWebhookSigningSecret = Read-Host -Prompt "Please enter the Webhook 'Signing secret' (Right click to paste)"

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
        -RequiredRole 'CanConfigureStripe'
}
catch {
    if ($_.ErrorDetails.Message -notlike '*invalid_client*') {
        throw
    }

    throw "The configured PAYMENTS_API_CLIENT_SECRET is invalid. Run infra/scripts/generate-payments-api-client-secret.ps1 to generate a new client secret, then rerun this script."
}

if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Could not acquire an application access token for api://$apiAppId. Ensure the client app has the CanConfigureStripe application role and admin consent."
}

$settings = @('STRIPE_CONFIGURATION_ENABLED=true')

try {
    Write-Host "Waiting for the Function App to apply Stripe configuration settings" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings $settings `
        --output none

    Restart-FunctionAppAndWait `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -FunctionAppUri $functionAppUri

    $configurationSetting = az functionapp config appsettings list `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --query "[?name=='STRIPE_CONFIGURATION_ENABLED'].value | [0]" `
        --output tsv
    Write-Host "Function App setting STRIPE_CONFIGURATION_ENABLED=$configurationSetting" -ForegroundColor Yellow

    Write-Host "Calling $functionAppUri/api/configuration/configure-stripe" -ForegroundColor Green
    Invoke-StripeConfigurationWithRetry `
        -Uri "$functionAppUri/api/configuration/configure-stripe" `
        -Token $token `
        -StripeApiKey $stripeApiKey `
        -StripeWebhookSecret $stripeWebhookSigningSecret
}
finally {
    Write-Host "Disabling the Stripe configuration endpoint" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings STRIPE_CONFIGURATION_ENABLED=false `
        --output none

    Restart-FunctionAppAndWait `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -FunctionAppUri $functionAppUri
}

Write-Host "Stripe configuration complete." -ForegroundColor Green
