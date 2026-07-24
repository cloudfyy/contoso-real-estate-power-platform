# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script will use the Azure deployment environment variables to create a deploymentSettings.json file for deployment of the ContosoRealEstateCore solution.
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

function Invoke-PaymentsApiClientSecretEndpoint {
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
                throw
            }

            Write-Host "Payments API client secret endpoint not ready yet (attempt $attempt/60, status $statusCode)." -ForegroundColor Yellow
        }

        Start-Sleep -Seconds 5
    }

    throw "The Function App did not return the Payments API client secret from '$Uri'. Authenticated calls kept returning a transient or disabled response."
}

function Get-PaymentsApiClientSecretFromFunction {
    param (
        [object]$EnvironmentVariables
    )

    $selectedAzureEnv = Get-RequiredValue $EnvironmentVariables.AZURE_ENV_NAME 'AZURE_ENV_NAME'
    $functionAppName = Get-RequiredValue $EnvironmentVariables.SERVICE_API_NAME 'SERVICE_API_NAME'
    $functionAppUri = Get-RequiredValue $EnvironmentVariables.SERVICE_API_URI 'SERVICE_API_URI'
    $resourceGroupName = Get-RequiredValue $EnvironmentVariables.AZURE_RESOURCE_GROUP 'AZURE_RESOURCE_GROUP'
    $apiAppId = Get-RequiredValue $EnvironmentVariables.ENTRA_API_APP_ID 'ENTRA_API_APP_ID'
    $apiClientAppId = Get-RequiredValue $EnvironmentVariables.ENTRA_API_CLIENT_APP_ID 'ENTRA_API_CLIENT_APP_ID'
    $tenantId = Get-RequiredValue $EnvironmentVariables.AZURE_TENANT_ID 'AZURE_TENANT_ID'

    Write-Host "Ensuring the Payments API client has the secret read role" -ForegroundColor Green
    & "$PSScriptRoot\..\..\..\..\infra\scripts\grant-access-to-payment-api.ps1" -azureEnv $selectedAzureEnv

    $apiClientSecret = az functionapp config appsettings list `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --query "[?name=='PAYMENTS_API_CLIENT_SECRET'].value | [0]" `
        --output tsv

    if ([string]::IsNullOrWhiteSpace($apiClientSecret)) {
        Write-Host "PAYMENTS_API_CLIENT_SECRET is not set. Falling back to MICROSOFT_PROVIDER_AUTHENTICATION_SECRET for this run." -ForegroundColor Yellow
        $apiClientSecret = az functionapp config appsettings list `
            --resource-group $resourceGroupName `
            --name $functionAppName `
            --query "[?name=='MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'].value | [0]" `
            --output tsv
    }

    if ([string]::IsNullOrWhiteSpace($apiClientSecret)) {
        throw "Could not read the Payments API client secret from Function App '$functionAppName'. Run azd provision to generate and apply the client secret."
    }

    $token = Get-PaymentsApiAccessTokenWithRole `
        -TenantId $tenantId `
        -ApiAppId $apiAppId `
        -ApiClientAppId $apiClientAppId `
        -ApiClientSecret $apiClientSecret `
        -RequiredRole 'CanReadPaymentsApiClientSecret'

    try {
        Write-Host "Temporarily enabling Payments API client secret read endpoint" -ForegroundColor Yellow
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

        $secretUri = "$($functionAppUri.TrimEnd('/'))/api/configuration/payments-api-client-secret"
        Write-Host "Reading Payments API client secret through the Function App" -ForegroundColor Green
        $secretResponse = Invoke-PaymentsApiClientSecretEndpoint -Uri $secretUri -Token $token

        if ([string]::IsNullOrWhiteSpace($secretResponse.value)) {
            throw "The Payments API client secret endpoint did not return a secret value."
        }

        return [string]$secretResponse.value
    }
    finally {
        Write-Host "Disabling Payments API client secret read endpoint" -ForegroundColor Yellow
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
}

# -----------------------------------------------------------------------
# Import the environment variables
. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv


# Get Tenant ID, Application ID, OAuth 2.0 authorization endpoint (v2), OAuth 2.0 token endpoint (v2)
$solutionPrefix = 'contoso'
$apiAppName = 'PaymentsApi'
$tenantId = $envVars.AZURE_TENANT_ID
$subscriptionId = $envVars.AZURE_SUBSCRIPTION_ID
$appHostUrl = $envVars.SERVICE_API_URI.TrimStart("https://")
$app = $envVars.ENTRA_API_CLIENT_APP_ID
$appResourceUri = $envVars.SERVICE_API_RESOURCE_URI
$apiUserAccessScope = "user_impersonation"

# Environment variable names
$tenantIdEnvVarName = "${solutionPrefix}_${apiAppName}TenantId";
$appIdEnvVarName = "${solutionPrefix}_${apiAppName}AppId";
$secretEnvVarName = "${solutionPrefix}_${apiAppName}Secret";
$resourceUrlEnvVarName = "${solutionPrefix}_${apiAppName}ResourceUrl";
$scopeEnvVarName = "${solutionPrefix}_${apiAppName}Scope";
$hostEnvVarName = "${solutionPrefix}_${apiAppName}Host";
$hostBaseUrlVarName = "${solutionPrefix}_${apiAppName}BaseUrl";
$deploymentSettingsEnvironmentVariables = "";

$secretValue = Get-PaymentsApiClientSecretFromFunction -EnvironmentVariables $envVars
$scope = "${appResourceUri}/${apiUserAccessScope}"

function EnvironmentVariableJson($schemaName, $value, [bool]$isLast = $false) {
    $json = @{
        "SchemaName" = $schemaName
        "Value" = $value
    } | ConvertTo-Json

    if (-not $isLast) {
        $json += "," + [Environment]::NewLine
    }

    return $json
}

$deploymentSettingsEnvironmentVariables += EnvironmentVariableJson $appIdEnvVarName $app
    
$deploymentSettingsEnvironmentVariables += EnvironmentVariableJson $hostBaseUrlVarName "/api"

$deploymentSettingsEnvironmentVariables += EnvironmentVariableJson $hostEnvVarName $appHostUrl

$deploymentSettingsEnvironmentVariables += EnvironmentVariableJson $resourceUrlEnvVarName $appResourceUri

$deploymentSettingsEnvironmentVariables += EnvironmentVariableJson $scopeEnvVarName $scope

$deploymentSettingsEnvironmentVariables += EnvironmentVariableJson $secretEnvVarName $secretValue

$deploymentSettingsEnvironmentVariables += EnvironmentVariableJson $tenantIdEnvVarName $tenantId $true


$deploymentSettings = @"
{
"EnvironmentVariables": [
$deploymentSettingsEnvironmentVariables
],
"ConnectionReferences": []
}
"@

# Output the deployment settings to the deploymentSettings_AZURE_ENV_NAM.json file
$azureEnv = $envVars.AZURE_ENV_NAME
$deploymentSettingsFilePath = "$PSScriptRoot\temp_deploymentSettings_${azureEnv}.json"

Write-Host "Generating deployment settings file at $deploymentSettingsFilePath" -ForegroundColor Green
Set-Content -Path $deploymentSettingsFilePath -Value $deploymentSettings
