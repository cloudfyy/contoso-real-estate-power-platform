# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script initializes the payments SQL database through the Payments API Function App.
param (
    [string]$azureEnv
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\payments-api-function-helpers.ps1"

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
            $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -notin @(404, 502, 503, 504)) {
                $responseBody = $_.ErrorDetails.Message
                if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                    try {
                        $errorResult = $responseBody | ConvertFrom-Json
                        Write-Host "Initialization endpoint returned status ${statusCode}: $($errorResult.message)" -ForegroundColor Red
                        Write-Host "Error: $($errorResult.error)" -ForegroundColor Red
                        Write-Host "Error type: $($errorResult.errorType)" -ForegroundColor Red
                    }
                    catch {
                        Write-Host "Initialization endpoint returned status ${statusCode}: $responseBody" -ForegroundColor Red
                    }
                }

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
$selectedAzureEnv = Get-RequiredValue $envVars.AZURE_ENV_NAME 'AZURE_ENV_NAME'

$sqlServerName = "$resourcePrefix-sql"
$sqlAdminGroupName = "$resourcePrefix-sql-admins"

Write-Host "Ensuring the current user has the Payments API initialization role" -ForegroundColor Green
& "$PSScriptRoot\grant-access-to-payment-api.ps1" -azureEnv $selectedAzureEnv

$sqlAdminGroup = Get-OrCreateGroup -DisplayName $sqlAdminGroupName
$currentUserObjectId = az ad signed-in-user show --query id --output tsv
$functionPrincipalId = az functionapp identity show `
    --resource-group $resourceGroupName `
    --name $functionAppName `
    --query principalId `
    --output tsv

$functionClientId = az ad sp show `
    --id $functionPrincipalId `
    --query appId `
    --output tsv

if ([string]::IsNullOrWhiteSpace($functionClientId)) {
    throw "Could not resolve the client id for Function App managed identity '$functionPrincipalId'."
}

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
            -RequiredRole 'CanInitializePaymentsDatabase'
    }
    catch {
        if ($_.ErrorDetails.Message -notlike '*invalid_client*') {
            throw
        }

        throw "The configured PAYMENTS_API_CLIENT_SECRET is invalid. Run infra/scripts/repair-payments-api-easyauth-secret.ps1 to repair the client secret, then rerun this script."
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Could not acquire an application access token for api://$apiAppId. Ensure the client app has the CanInitializePaymentsDatabase application role and admin consent."
    }

    $settings = @(
        'SQL_INITIALIZATION_ENABLED=true',
        "SQL_MANAGED_IDENTITY_CLIENT_ID=$functionClientId",
        "SQL_MANAGED_IDENTITY_OBJECT_ID=$functionClientId"
    )

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

    Write-Host "Calling $functionAppUri/api/configuration/initialize-sql" -ForegroundColor Green
    Invoke-SqlInitializationWithRetry `
        -Uri "$functionAppUri/api/configuration/initialize-sql" `
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