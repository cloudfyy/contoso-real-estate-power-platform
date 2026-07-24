# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

$scriptPath = Join-Path $PSScriptRoot '..\infra\scripts\write-payments-api-client-secret-to-key-vault.ps1'
& $scriptPath -azureEnv $env:AZURE_ENV_NAME

Write-Host @"

Deployment completed. After deploying your Power Platform solution, you can run the following
command to update the solution to match this environment:

./infra/scripts/post-deployment-setup.ps1

"@ -ForegroundColor Green