# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

$ErrorActionPreference = 'Stop'

function Get-RequiredEnvironmentVariable {
	param (
		[string]$Name
	)

	$value = [Environment]::GetEnvironmentVariable($Name)
	if ([string]::IsNullOrWhiteSpace($value)) {
		throw "Required environment variable '$Name' was not set. Run this hook from azd after provisioning."
	}

	return $value
}

$clientAppObjectId = Get-RequiredEnvironmentVariable 'ENTRA_API_CLIENT_OBJECT_ID'
$clientAppId = Get-RequiredEnvironmentVariable 'ENTRA_API_CLIENT_APP_ID'
$resourceGroupName = Get-RequiredEnvironmentVariable 'AZURE_RESOURCE_GROUP'
$functionAppName = Get-RequiredEnvironmentVariable 'SERVICE_API_NAME'

$credentialDisplayName = 'Client Secret for OAuth'
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
		throw "Microsoft Graph addPassword request failed. $(($credentialResult | Out-String).Trim())"
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
