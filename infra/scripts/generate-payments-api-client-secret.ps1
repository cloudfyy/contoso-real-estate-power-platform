# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\payments-api-function-helpers.ps1"

function Get-RequiredEnvironmentVariable {
	param (
		[string]$Name
	)

	$value = Get-RequiredValue ([Environment]::GetEnvironmentVariable($Name)) $Name
	return $value
}

function Get-FunctionAppSetting {
	param (
		[string]$ResourceGroupName,
		[string]$FunctionAppName,
		[string]$Name
	)

	return az functionapp config appsettings list `
		--resource-group $ResourceGroupName `
		--name $FunctionAppName `
		--query "[?name=='$Name'].value | [0]" `
		--output tsv
}

function Test-ClientSecret {
	param (
		[string]$TenantId,
		[string]$ClientAppId,
		[string]$ApiAppId,
		[string]$ClientSecret
	)

	if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
		return $false
	}

	try {
		$token = Get-PaymentsApiAccessToken `
			-TenantId $TenantId `
			-ApiAppId $ApiAppId `
			-ApiClientAppId $ClientAppId `
			-ApiClientSecret $ClientSecret

		return -not [string]::IsNullOrWhiteSpace($token)
	}
	catch {
		Write-Host "Existing Entra client secret is not usable. $($_.Exception.Message)" -ForegroundColor Yellow
		return $false
	}
}

$clientAppObjectId = Get-RequiredEnvironmentVariable 'ENTRA_API_CLIENT_OBJECT_ID'
$clientAppId = Get-RequiredEnvironmentVariable 'ENTRA_API_CLIENT_APP_ID'
$apiAppId = Get-RequiredEnvironmentVariable 'ENTRA_API_APP_ID'
$tenantId = Get-RequiredEnvironmentVariable 'AZURE_TENANT_ID'
$resourceGroupName = Get-RequiredEnvironmentVariable 'AZURE_RESOURCE_GROUP'
$functionAppName = Get-RequiredEnvironmentVariable 'SERVICE_API_NAME'

$credentialDisplayName = 'Client Secret for OAuth'
$existingClientSecret = Get-FunctionAppSetting `
	-ResourceGroupName $resourceGroupName `
	-FunctionAppName $functionAppName `
	-Name 'PAYMENTS_API_CLIENT_SECRET'

if (Test-ClientSecret -TenantId $tenantId -ClientAppId $clientAppId -ApiAppId $apiAppId -ClientSecret $existingClientSecret) {
	Write-Host 'Existing Entra client secret is still valid. Skipping secret generation.' -ForegroundColor Green
	return
}

$endDateTime = (Get-Date).ToUniversalTime().AddDays(60).ToString('yyyy-MM-ddTHH:mm:ssZ')
$body = @{
	passwordCredential = @{
		displayName = $credentialDisplayName
		endDateTime = $endDateTime
	}
} | ConvertTo-Json -Depth 4 -Compress

Write-Host "Generating Entra client secret for application object '$clientAppObjectId'"
$bodyFile = New-TemporaryFile
Set-Content -Path $bodyFile -Value $body -Encoding utf8

try {
	$credentialResult = az rest `
		--method post `
		--url "https://graph.microsoft.com/v1.0/applications/$clientAppObjectId/addPassword" `
		--body "@$bodyFile" `
		--headers 'Content-Type=application/json' `
		--output json 2>&1

	if ($LASTEXITCODE -ne 0) {
		$errorMessage = ($credentialResult | Out-String).Trim()
		if ($errorMessage -match 'InteractionRequired|TokenCreatedWithOutdatedPolicies|InvalidAuthenticationToken') {
			throw "Microsoft Graph requires a fresh Azure CLI login before a new client secret can be generated. No Function App settings were updated. Run 'az logout', then 'az login --tenant $tenantId', then rerun 'azd provision --environment <environment-name>'. Original error: $errorMessage"
		}

		throw "Microsoft Graph addPassword request failed. $errorMessage"
	}

	$credential = $credentialResult | ConvertFrom-Json
}
finally {
	Remove-Item -Path $bodyFile -Force
}

if ([string]::IsNullOrWhiteSpace($credential.secretText)) {
	throw 'Microsoft Graph did not return a generated client secret.'
}

Write-Host "Updating Function App authentication secret setting"
az functionapp config appsettings set `
	--resource-group $resourceGroupName `
	--name $functionAppName `
	--settings "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=$($credential.secretText)" "PAYMENTS_API_CLIENT_SECRET=$($credential.secretText)" `
	--output none

$existingCredentials = az ad app credential list --id $clientAppId --output json | ConvertFrom-Json
$existingCredentials |
	Where-Object { $_.displayName -eq $credentialDisplayName -and $_.keyId -ne $credential.keyId } |
	ForEach-Object {
		Write-Host "Removing previous Entra client secret '$($_.keyId)'"
		az ad app credential delete --id $clientAppId --key-id $_.keyId --output none
	}

Write-Host 'Entra client secret generated and applied.' -ForegroundColor Green
