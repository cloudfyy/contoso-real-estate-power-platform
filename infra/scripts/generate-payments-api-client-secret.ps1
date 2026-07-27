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

$clientAppObjectId = Get-RequiredEnvironmentVariable 'ENTRA_API_CLIENT_OBJECT_ID'
$clientAppId = Get-RequiredEnvironmentVariable 'ENTRA_API_CLIENT_APP_ID'
$apiAppObjectId = Get-RequiredEnvironmentVariable 'ENTRA_API_OBJECT_ID'
$apiAppId = Get-RequiredEnvironmentVariable 'ENTRA_API_APP_ID'
$tenantId = Get-RequiredEnvironmentVariable 'AZURE_TENANT_ID'
$resourceGroupName = Get-RequiredEnvironmentVariable 'AZURE_RESOURCE_GROUP'
$functionAppName = Get-RequiredEnvironmentVariable 'SERVICE_API_NAME'

$paymentsApiClientCredentialDisplayName = 'Client Secret for OAuth'
$easyAuthCredentialDisplayName = 'Client Secret for EasyAuth'
$existingPaymentsApiClientSecret = Get-FunctionAppSetting `
	-ResourceGroupName $resourceGroupName `
	-FunctionAppName $functionAppName `
	-Name 'PAYMENTS_API_CLIENT_SECRET'

$existingEasyAuthSecret = Get-FunctionAppSetting `
	-ResourceGroupName $resourceGroupName `
	-FunctionAppName $functionAppName `
	-Name 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'

$paymentsApiClientSecretGenerated = $false
$paymentsApiClientSecretEndDateTime = $null
$easyAuthSecretGenerated = $false
$easyAuthSecretEndDateTime = $null

if (Test-EasyAuthClientSecret -TenantId $tenantId -ApiAppId $apiAppId -ClientSecret $existingEasyAuthSecret) {
	Write-Host 'Existing EasyAuth client secret is still valid. Skipping EasyAuth secret generation.' -ForegroundColor Green
}
else {
	$easyAuthCredential = New-EntraClientSecret `
		-ApplicationObjectId $apiAppObjectId `
		-DisplayName $easyAuthCredentialDisplayName `
		-TenantId $tenantId

	Write-Host 'Updating Function App EasyAuth secret setting'
	az functionapp config appsettings set `
		--resource-group $resourceGroupName `
		--name $functionAppName `
		--settings "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=$($easyAuthCredential.SecretText)" `
		--output none

	Remove-PreviousEntraClientSecrets `
		-ApplicationId $apiAppId `
		-DisplayName $easyAuthCredentialDisplayName `
		-CurrentKeyId $easyAuthCredential.KeyId

	$easyAuthSecretGenerated = $true
	$easyAuthSecretEndDateTime = $easyAuthCredential.EndDateTime
}

if (Test-PaymentsApiClientSecret -TenantId $tenantId -ClientAppId $clientAppId -ApiAppId $apiAppId -ClientSecret $existingPaymentsApiClientSecret) {
	Write-Host 'Existing Payments API client secret is still valid. Skipping Payments API client secret generation.' -ForegroundColor Green
}
else {
	$paymentsApiClientCredential = New-EntraClientSecret `
		-ApplicationObjectId $clientAppObjectId `
		-DisplayName $paymentsApiClientCredentialDisplayName `
		-TenantId $tenantId

	Write-Host 'Updating Function App Payments API client secret setting'
	az functionapp config appsettings set `
		--resource-group $resourceGroupName `
		--name $functionAppName `
		--settings "PAYMENTS_API_CLIENT_SECRET=$($paymentsApiClientCredential.SecretText)" `
		--output none

	Remove-PreviousEntraClientSecrets `
		-ApplicationId $clientAppId `
		-DisplayName $paymentsApiClientCredentialDisplayName `
		-CurrentKeyId $paymentsApiClientCredential.KeyId

	$paymentsApiClientSecretGenerated = $true
	$paymentsApiClientSecretEndDateTime = $paymentsApiClientCredential.EndDateTime
}

if ($easyAuthSecretGenerated -or $paymentsApiClientSecretGenerated) {
	Write-Host "Restarting Function App '$functionAppName'"
	az functionapp restart `
		--resource-group $resourceGroupName `
		--name $functionAppName `
		--output none
}

Write-Host 'Entra client secrets are valid and applied.' -ForegroundColor Green

@{
	generated = $easyAuthSecretGenerated -or $paymentsApiClientSecretGenerated
	easyAuthSecretGenerated = $easyAuthSecretGenerated
	easyAuthSecretEndDateTime = $easyAuthSecretEndDateTime
	paymentsApiClientSecretGenerated = $paymentsApiClientSecretGenerated
	paymentsApiClientSecretEndDateTime = $paymentsApiClientSecretEndDateTime
} | ConvertTo-Json -Compress
