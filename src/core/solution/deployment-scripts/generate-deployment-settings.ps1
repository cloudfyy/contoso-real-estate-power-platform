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

# -----------------------------------------------------------------------
# Import the environment variables
. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv


# Get Tenant ID, Application ID, OAuth 2.0 authorization endpoint (v2), OAuth 2.0 token endpoint (v2)
$solutionPrefix = 'contoso'
$apiAppName = 'PaymentsApi'
$tenantId = $envVars.AZURE_TENANT_ID
$appHostUrl = $envVars.SERVICE_API_URI.TrimStart("https://")
$app = $envVars.ENTRA_API_CLIENT_APP_ID
$appResourceUri = $envVars.SERVICE_API_RESOURCE_URI
$apiUserAccessScope = "user_impersonation"

# Environment variable names
$tenantIdEnvVarName = "${solutionPrefix}_${apiAppName}TenantId";
$appIdEnvVarName = "${solutionPrefix}_${apiAppName}AppId";
$resourceUrlEnvVarName = "${solutionPrefix}_${apiAppName}ResourceUrl";
$scopeEnvVarName = "${solutionPrefix}_${apiAppName}Scope";
$hostEnvVarName = "${solutionPrefix}_${apiAppName}Host";
$hostBaseUrlVarName = "${solutionPrefix}_${apiAppName}BaseUrl";
$deploymentSettingsEnvironmentVariables = "";

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
