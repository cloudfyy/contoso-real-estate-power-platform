# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

$scriptPath = Join-Path $PSScriptRoot '..\infra\scripts\write-payments-api-client-secret-to-key-vault.ps1'
& $scriptPath -azureEnv $env:AZURE_ENV_NAME

$scriptPath = Join-Path $PSScriptRoot '..\infra\scripts\initialize-sql-via-function.ps1'
& $scriptPath -azureEnv $env:AZURE_ENV_NAME

Write-Host @"

Deployment completed. After creating your Stripe account and webhook, run the following
command to configure Stripe secrets:

./infra/scripts/configure-stripe-and-validate-payments.ps1

"@ -ForegroundColor Green