# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script sets up the stripe payment keys
# -----------------------------------------------------------------------
param (
    [string]$azureEnv
)

$ErrorActionPreference = 'Stop'

function Get-RequiredValue {
    param (
        [object]$Value,
        [string]$Name
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Required environment value '$Name' was not set. Run azd provision first."
    }

    return [string]$Value
}

function Get-PaymentsApiAccessToken {
    param (
        [string]$TenantId,
        [string]$ApiAppId,
        [string]$ApiClientAppId,
        [string]$ApiClientSecret,
        [int]$RetryCount = 1
    )

    $body = @{
        client_id = $ApiClientAppId
        client_secret = $ApiClientSecret
        grant_type = 'client_credentials'
        scope = "api://$ApiAppId/.default"
    }
    $encodedBody = ($body.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f [System.Net.WebUtility]::UrlEncode($_.Key), [System.Net.WebUtility]::UrlEncode($_.Value)
    }) -join '&'

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $tokenResponse = Invoke-RestMethod `
                -Method Post `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -ContentType 'application/x-www-form-urlencoded' `
                -Body $encodedBody

            return $tokenResponse.access_token
        }
        catch {
            if ($_.ErrorDetails.Message -notlike '*invalid_client*' -or $attempt -eq $RetryCount) {
                throw
            }

            Start-Sleep -Seconds 5
        }
    }
}

function ConvertFrom-Base64Url {
    param (
        [string]$Value
    )

    $base64 = $Value.Replace('-', '+').Replace('_', '/')
    switch ($base64.Length % 4) {
        2 { $base64 += '==' }
        3 { $base64 += '=' }
    }

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))
}

function Get-JwtPayload {
    param (
        [string]$Token
    )

    $parts = $Token.Split('.')
    if ($parts.Length -lt 2) {
        throw 'The Payments API access token was not a valid JWT.'
    }

    return ConvertFrom-Json (ConvertFrom-Base64Url -Value $parts[1])
}

function Get-ClaimValues {
    param (
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ })
    }

    return @([string]$Value)
}

function Get-PaymentsApiAccessTokenWithRole {
    param (
        [string]$TenantId,
        [string]$ApiAppId,
        [string]$ApiClientAppId,
        [string]$ApiClientSecret,
        [string]$RequiredRole,
        [int]$RetryCount = 36
    )

    $expectedAudience = "api://$ApiAppId"
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $token = Get-PaymentsApiAccessToken `
            -TenantId $TenantId `
            -ApiAppId $ApiAppId `
            -ApiClientAppId $ApiClientAppId `
            -ApiClientSecret $ApiClientSecret

        $payload = Get-JwtPayload -Token $token
        $audiences = Get-ClaimValues -Value $payload.aud
        $roles = Get-ClaimValues -Value $payload.roles

        if ($audiences -contains $expectedAudience -and $roles -contains $RequiredRole) {
            Write-Host "Access token contains audience '$expectedAudience' and role '$RequiredRole'." -ForegroundColor Yellow
            return $token
        }

        $audienceDisplay = if ($audiences.Count -gt 0) { $audiences -join ', ' } else { '<none>' }
        $roleDisplay = if ($roles.Count -gt 0) { $roles -join ', ' } else { '<none>' }
        Write-Host "Access token does not contain the expected claims yet (attempt $attempt/$RetryCount, aud: $audienceDisplay, roles: $roleDisplay)." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }

    throw "Could not acquire an access token containing audience '$expectedAudience' and role '$RequiredRole'. Check the app role assignment and admin consent for client app '$ApiClientAppId'."
}

function Restart-FunctionAppAndWait {
    param (
        [string]$ResourceGroupName,
        [string]$FunctionAppName,
        [string]$FunctionAppUri
    )

    Write-Host "Restarting Function App '$FunctionAppName'" -ForegroundColor Yellow
    az functionapp restart `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --output none

    $readinessProbeUri = "$FunctionAppUri/api/ping/function-ready"
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            Invoke-RestMethod -Method Get -Uri $readinessProbeUri | Out-Null
            return
        }
        catch {
            $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            Write-Host "Function App is not ready yet (attempt $attempt/60, status $statusCode)." -ForegroundColor Yellow
        }

        Start-Sleep -Seconds 5
    }

    throw "Function App '$FunctionAppName' did not become ready after restart. Last checked '$readinessProbeUri'."
}

function Wait-FunctionAppSetting {
    param (
        [string]$ResourceGroupName,
        [string]$FunctionAppName,
        [string]$Name,
        [string]$ExpectedValue,
        [switch]$RedactValue
    )

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $actualValue = az functionapp config appsettings list `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --query "[?name=='$Name'].value | [0]" `
            --output tsv

        if ($actualValue -eq $ExpectedValue) {
            $displayValue = if ($RedactValue) { '<redacted>' } else { $actualValue }
            Write-Host "Function App setting $Name=$displayValue" -ForegroundColor Yellow
            return
        }

        $displayValue = if ($RedactValue) { '<redacted>' } else { $actualValue }
        Write-Host "Waiting for Function App setting $Name to match expected value (attempt $attempt/30, current value '$displayValue')." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }

    throw "Function App setting '$Name' did not become the expected value."
}

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
    throw "Could not read PAYMENTS_API_CLIENT_SECRET from Function App '$functionAppName'. Run azd provision, or run infra/scripts/repair-payments-api-easyauth-secret.ps1 if the configured client secret is invalid."
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

    throw "The configured PAYMENTS_API_CLIENT_SECRET is invalid. Run infra/scripts/repair-payments-api-easyauth-secret.ps1 to repair the client secret, then rerun this script."
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
