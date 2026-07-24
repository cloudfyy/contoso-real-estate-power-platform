# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script repairs the Function App EasyAuth secret used by the Payments API app registration.
# -----------------------------------------------------------------------
param (
    [string]$azureEnv,
    [switch]$SkipRestart
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

function New-EasyAuthClientSecret {
    param (
        [string]$ApiApplicationObjectId
    )

    $body = @{
        passwordCredential = @{
            displayName = 'Client Secret for EasyAuth'
            endDateTime = (Get-Date).ToUniversalTime().AddDays(60).ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    } | ConvertTo-Json -Depth 4 -Compress

    Write-Host "Generating a new EasyAuth client secret for the Payments API app registration" -ForegroundColor Yellow
    $bodyFile = New-TemporaryFile
    Set-Content -Path $bodyFile -Value $body -Encoding utf8

    try {
        $credential = az rest `
            --method post `
            --url "https://graph.microsoft.com/v1.0/applications/$ApiApplicationObjectId/addPassword" `
            --body "@$bodyFile" `
            --headers 'Content-Type=application/json' `
            --output json | ConvertFrom-Json
    }
    finally {
        Remove-Item -Path $bodyFile -Force
    }

    if ([string]::IsNullOrWhiteSpace($credential.secretText)) {
        throw 'Microsoft Graph did not return a generated EasyAuth client secret. The Function App setting was not changed.'
    }

    return $credential.secretText
}

function Wait-FunctionAppSetting {
    param (
        [string]$ResourceGroupName,
        [string]$FunctionAppName,
        [string]$Name,
        [string]$ExpectedValue
    )

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $actualValue = az functionapp config appsettings list `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --query "[?name=='$Name'].value | [0]" `
            --output tsv

        if ($actualValue -eq $ExpectedValue) {
            Write-Host "Function App setting $Name=<redacted>" -ForegroundColor Yellow
            return
        }

        Write-Host "Waiting for Function App setting $Name to match expected value (attempt $attempt/30, current value '<redacted>')." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }

    throw "Function App setting '$Name' did not become the expected value."
}

function Test-EasyAuthClientSecret {
    param (
        [string]$TenantId,
        [string]$ApiApplicationId,
        [string]$ClientSecret
    )

    $body = @{
        client_id = $ApiApplicationId
        client_secret = $ClientSecret
        grant_type = 'client_credentials'
        scope = "api://$ApiApplicationId/.default"
    }

    Write-Host "Validating MICROSOFT_PROVIDER_AUTHENTICATION_SECRET against the Payments API app registration" -ForegroundColor Yellow
    $tokenResponse = Invoke-RestMethod `
        -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $body

    if ([string]::IsNullOrWhiteSpace($tokenResponse.access_token)) {
        throw 'The token endpoint did not return an access token for the repaired EasyAuth secret.'
    }
}

. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv

$functionAppName = Get-RequiredValue $envVars.SERVICE_API_NAME 'SERVICE_API_NAME'
$resourceGroupName = Get-RequiredValue $envVars.AZURE_RESOURCE_GROUP 'AZURE_RESOURCE_GROUP'
$tenantId = Get-RequiredValue $envVars.AZURE_TENANT_ID 'AZURE_TENANT_ID'
$apiAppId = Get-RequiredValue $envVars.ENTRA_API_APP_ID 'ENTRA_API_APP_ID'
$apiObjectId = Get-RequiredValue $envVars.ENTRA_API_OBJECT_ID 'ENTRA_API_OBJECT_ID'

$easyAuthSecret = New-EasyAuthClientSecret -ApiApplicationObjectId $apiObjectId

Write-Host "Updating Function App EasyAuth secret setting" -ForegroundColor Yellow
az functionapp config appsettings set `
    --resource-group $resourceGroupName `
    --name $functionAppName `
    --settings "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=$easyAuthSecret" `
    --output none

Wait-FunctionAppSetting `
    -ResourceGroupName $resourceGroupName `
    -FunctionAppName $functionAppName `
    -Name 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET' `
    -ExpectedValue $easyAuthSecret

Test-EasyAuthClientSecret `
    -TenantId $tenantId `
    -ApiApplicationId $apiAppId `
    -ClientSecret $easyAuthSecret

if ($SkipRestart) {
    Write-Host "Skipping Function App restart because -SkipRestart was provided." -ForegroundColor Yellow
}
else {
    Write-Host "Restarting Function App '$functionAppName'" -ForegroundColor Yellow
    az functionapp restart `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --output none
}

Write-Host "Payments API EasyAuth secret repair complete." -ForegroundColor Green