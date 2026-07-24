# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script runs the post deployment steps after running azd up
# -----------------------------------------------------------------------
param (
	[string]$azureEnv
)

. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv
$envName = $envVars.AZURE_ENV_NAME

CheckPACCLI
CheckAZCLI

. "$PSScriptRoot\set-custom-connector-reply-url.ps1" -azureEnv $envName -skipLoginChecks $true
. "$PSScriptRoot\configure-plugin-managed-identity.ps1" -azureEnv $envName -skipLoginChecks $true
