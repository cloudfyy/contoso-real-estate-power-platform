# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script configures Stripe and validates the Payments configuration after running azd up
# -----------------------------------------------------------------------
. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables
$envName = $envVars.AZURE_ENV_NAME

. "$PSScriptRoot\setup-stripe.ps1" -azureEnv $envName
. "$PSScriptRoot\validate-payments-configuration.ps1" -azureEnv $envName