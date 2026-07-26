# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

$scriptPath = Join-Path $PSScriptRoot '..\infra\scripts\generate-payments-api-client-secret.ps1'
$secretGenerationResult = & $scriptPath

$secretGenerationJson = $secretGenerationResult | Select-Object -Last 1
$secretGeneration = $null
if (-not [string]::IsNullOrWhiteSpace($secretGenerationJson)) {
	try {
		$secretGeneration = $secretGenerationJson | ConvertFrom-Json
	}
	catch {
		Write-Host "Could not parse secret generation output as JSON; continuing without secret expiration metadata." -ForegroundColor Yellow
	}
}

$secretExpiresOn = if ($null -ne $secretGeneration) { [string]$secretGeneration.endDateTime } else { $null }

$scriptPath = Join-Path $PSScriptRoot '..\infra\scripts\write-payments-api-client-secret-to-key-vault.ps1'
& $scriptPath -azureEnv $env:AZURE_ENV_NAME -secretExpiresOn $secretExpiresOn

$scriptPath = Join-Path $PSScriptRoot '..\infra\scripts\initialize-sql-via-function.ps1'
& $scriptPath -azureEnv $env:AZURE_ENV_NAME

Write-Host @"

Deployment completed. After creating your Stripe account and webhook, run the following
command to configure Stripe secrets:

./infra/scripts/configure-stripe-and-validate-payments.ps1

"@ -ForegroundColor Green