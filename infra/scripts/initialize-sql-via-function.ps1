# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script initializes the payments SQL database through the Payments API Function App.
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

function Get-OrCreateGroup {
    param (
        [string]$DisplayName
    )

    $group = az ad group list `
        --display-name $DisplayName `
        --query "[0].{id:id, displayName:displayName}" `
        --output json | ConvertFrom-Json

    if ($null -ne $group -and -not [string]::IsNullOrWhiteSpace($group.id)) {
        return $group
    }

    return az ad group create `
        --display-name $DisplayName `
        --mail-nickname $DisplayName `
        --query "{id:id, displayName:displayName}" `
        --output json | ConvertFrom-Json
}

function Add-GroupMemberIfMissing {
    param (
        [string]$GroupId,
        [string]$MemberId
    )

    $isMember = az ad group member check `
        --group $GroupId `
        --member-id $MemberId `
        --query value `
        --output tsv

    if ($isMember -ne 'true') {
        az ad group member add --group $GroupId --member-id $MemberId --output none
    }
}

function Remove-GroupMemberIfPresent {
    param (
        [string]$GroupId,
        [string]$MemberId
    )

    $isMember = az ad group member check `
        --group $GroupId `
        --member-id $MemberId `
        --query value `
        --output tsv

    if ($isMember -eq 'true') {
        az ad group member remove --group $GroupId --member-id $MemberId --output none
    }
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

function New-PaymentsApiClientSecret {
    param (
        [string]$ClientAppObjectId
    )

    $body = @{
        passwordCredential = @{
            displayName = 'Client Secret for SQL initialization'
            endDateTime = (Get-Date).ToUniversalTime().AddDays(60).ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    } | ConvertTo-Json -Depth 4 -Compress

    Write-Host "Generating a new Payments API client secret" -ForegroundColor Yellow
    $bodyFile = New-TemporaryFile
    Set-Content -Path $bodyFile -Value $body -Encoding utf8

    try {
        $credential = az rest `
            --method post `
            --url "https://graph.microsoft.com/v1.0/applications/$ClientAppObjectId/addPassword" `
            --body "@$bodyFile" `
            --headers 'Content-Type=application/json' `
            --output json | ConvertFrom-Json
    }
    finally {
        Remove-Item -Path $bodyFile -Force
    }

    if ([string]::IsNullOrWhiteSpace($credential.secretText)) {
        throw 'Microsoft Graph did not return a generated client secret.'
    }

    return $credential.secretText
}

function Invoke-SqlInitializationWithRetry {
    param (
        [string]$Uri,
        [string]$Token
    )

    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            return Invoke-RestMethod `
                -Method Post `
                -Uri $Uri `
                -Headers @{ Authorization = "Bearer $Token" }
        }
        catch {
            $statusCode = [int]$_.Exception.Response.StatusCode
            if ($statusCode -notin @(404, 502, 503, 504)) {
                throw
            }

            $responseBody = $_.ErrorDetails.Message
            if ([string]::IsNullOrWhiteSpace($responseBody)) {
                Write-Host "Initialization endpoint not ready yet (attempt $attempt/60, status $statusCode)." -ForegroundColor Yellow
            }
            else {
                Write-Host "Initialization endpoint not ready yet (attempt $attempt/60, status $statusCode): $responseBody" -ForegroundColor Yellow
            }
        }

        Start-Sleep -Seconds 5
    }

    throw "The Function App did not apply SQL initialization settings. Authenticated calls to '$Uri' kept returning a transient or disabled response."
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

Write-Host "Initializing the payments SQL database through the Function App" -ForegroundColor White

. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv

$resourceGroupName = Get-RequiredValue $envVars.AZURE_RESOURCE_GROUP 'AZURE_RESOURCE_GROUP'
$resourcePrefix = Get-RequiredValue $envVars.AZURE_RESOURCE_PREFIX 'AZURE_RESOURCE_PREFIX'
$functionAppName = Get-RequiredValue $envVars.SERVICE_API_NAME 'SERVICE_API_NAME'
$functionAppUri = Get-RequiredValue $envVars.SERVICE_API_URI 'SERVICE_API_URI'
$apiAppId = Get-RequiredValue $envVars.ENTRA_API_APP_ID 'ENTRA_API_APP_ID'
$apiClientAppId = Get-RequiredValue $envVars.ENTRA_API_CLIENT_APP_ID 'ENTRA_API_CLIENT_APP_ID'
$apiClientObjectId = Get-RequiredValue $envVars.ENTRA_API_CLIENT_OBJECT_ID 'ENTRA_API_CLIENT_OBJECT_ID'
$tenantId = Get-RequiredValue $envVars.AZURE_TENANT_ID 'AZURE_TENANT_ID'

$sqlServerName = "$resourcePrefix-sql"
$sqlAdminGroupName = "$resourcePrefix-sql-admins"

Write-Host "Ensuring the current user has the Payments API initialization role" -ForegroundColor Green
& "$PSScriptRoot\grant-access-to-payment-api.ps1" -azureEnv $azureEnv

$sqlAdminGroup = Get-OrCreateGroup -DisplayName $sqlAdminGroupName
$currentUserObjectId = az ad signed-in-user show --query id --output tsv
$functionPrincipalId = az functionapp identity show `
    --resource-group $resourceGroupName `
    --name $functionAppName `
    --query principalId `
    --output tsv

Write-Host "Adding current user and Function App identity to SQL admin group '$($sqlAdminGroup.displayName)'" -ForegroundColor Green
Add-GroupMemberIfMissing -GroupId $sqlAdminGroup.id -MemberId $currentUserObjectId
Add-GroupMemberIfMissing -GroupId $sqlAdminGroup.id -MemberId $functionPrincipalId

Write-Host "Setting SQL Entra administrator to '$($sqlAdminGroup.displayName)'" -ForegroundColor Green
az sql server ad-admin create `
    --resource-group $resourceGroupName `
    --server-name $sqlServerName `
    --display-name $sqlAdminGroup.displayName `
    --object-id $sqlAdminGroup.id `
    --output none

try {
    $apiClientSecretGenerated = $false
    $apiClientSecret = az functionapp config appsettings list `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --query "[?name=='MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'].value | [0]" `
        --output tsv

    if ([string]::IsNullOrWhiteSpace($apiClientSecret)) {
        throw "Could not read the Payments API client secret from Function App '$functionAppName'. Run azd provision to generate and apply the client secret."
    }

    try {
        $token = Get-PaymentsApiAccessToken -TenantId $tenantId -ApiAppId $apiAppId -ApiClientAppId $apiClientAppId -ApiClientSecret $apiClientSecret -RetryCount 36
    }
    catch {
        if ($_.ErrorDetails.Message -notlike '*invalid_client*') {
            throw
        }

        $apiClientSecret = New-PaymentsApiClientSecret `
            -ClientAppObjectId $apiClientObjectId
        $apiClientSecretGenerated = $true

        $token = Get-PaymentsApiAccessToken -TenantId $tenantId -ApiAppId $apiAppId -ApiClientAppId $apiClientAppId -ApiClientSecret $apiClientSecret -RetryCount 36
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Could not acquire an application access token for api://$apiAppId. Ensure the client app has the CanInitializePaymentsDatabase application role and admin consent."
    }

    $settings = @(
        'SQL_INITIALIZATION_ENABLED=true',
        "SQL_MANAGED_IDENTITY_OBJECT_ID=$functionPrincipalId"
    )
    if ($apiClientSecretGenerated) {
        $settings += "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=$apiClientSecret"
    }

    Write-Host "Waiting for the Function App to apply initialization settings" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings $settings `
        --output none

    Restart-FunctionAppAndWait `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -FunctionAppUri $functionAppUri

    $initializationSetting = az functionapp config appsettings list `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --query "[?name=='SQL_INITIALIZATION_ENABLED'].value | [0]" `
        --output tsv
    Write-Host "Function App setting SQL_INITIALIZATION_ENABLED=$initializationSetting" -ForegroundColor Yellow

    Write-Host "Calling $functionAppUri/api/database/initialize-sql" -ForegroundColor Green
    Invoke-SqlInitializationWithRetry `
        -Uri "$functionAppUri/api/database/initialize-sql" `
        -Token $token
}
finally {
    Write-Host "Disabling the SQL initialization endpoint" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings SQL_INITIALIZATION_ENABLED=false `
        --output none

    Restart-FunctionAppAndWait `
        -ResourceGroupName $resourceGroupName `
        -FunctionAppName $functionAppName `
        -FunctionAppUri $functionAppUri

    Write-Host "Removing Function App identity from temporary SQL admin group membership" -ForegroundColor Yellow
    Remove-GroupMemberIfPresent -GroupId $sqlAdminGroup.id -MemberId $functionPrincipalId
}

Write-Host "Payments SQL database initialization complete." -ForegroundColor Green