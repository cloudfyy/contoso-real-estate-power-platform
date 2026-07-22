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

Write-Host "Initializing the payments SQL database through the Function App" -ForegroundColor White

. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv

$resourceGroupName = Get-RequiredValue $envVars.AZURE_RESOURCE_GROUP 'AZURE_RESOURCE_GROUP'
$resourcePrefix = Get-RequiredValue $envVars.AZURE_RESOURCE_PREFIX 'AZURE_RESOURCE_PREFIX'
$functionAppName = Get-RequiredValue $envVars.SERVICE_API_NAME 'SERVICE_API_NAME'
$functionAppUri = Get-RequiredValue $envVars.SERVICE_API_URI 'SERVICE_API_URI'
$apiAppId = Get-RequiredValue $envVars.ENTRA_API_APP_ID 'ENTRA_API_APP_ID'

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
    Write-Host "Enabling the SQL initialization endpoint" -ForegroundColor Green
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings SQL_INITIALIZATION_ENABLED=true `
        --output none

    $token = az account get-access-token `
        --resource "api://$apiAppId" `
        --query accessToken `
        --output tsv

    Write-Host "Calling $functionAppUri/api/admin/initialize-sql" -ForegroundColor Green
    Invoke-RestMethod `
        -Method Post `
        -Uri "$functionAppUri/api/admin/initialize-sql" `
        -Headers @{ Authorization = "Bearer $token" }
}
finally {
    Write-Host "Disabling the SQL initialization endpoint" -ForegroundColor Yellow
    az functionapp config appsettings set `
        --resource-group $resourceGroupName `
        --name $functionAppName `
        --settings SQL_INITIALIZATION_ENABLED=false `
        --output none

    Write-Host "Removing Function App identity from temporary SQL admin group membership" -ForegroundColor Yellow
    Remove-GroupMemberIfPresent -GroupId $sqlAdminGroup.id -MemberId $functionPrincipalId
}

Write-Host "Payments SQL database initialization complete." -ForegroundColor Green