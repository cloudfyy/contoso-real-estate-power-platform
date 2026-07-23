# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script runs the post deployment steps after running azd up
# -----------------------------------------------------------------------
. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables
$envName = $envVars.AZURE_ENV_NAME

. "$PSScriptRoot\initialize-sql-via-function.ps1" -azureEnv $envName
. "$PSScriptRoot\setup-stripe.ps1" -azureEnv $envName