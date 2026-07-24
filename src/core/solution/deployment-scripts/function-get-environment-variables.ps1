# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
$commonEnvironmentScript = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\scripts\common\environment-variables.ps1'
. $commonEnvironmentScript

function GetEnvironmentVariables {
    param (
        [string]$azureEnv
    )
    return GetRepositoryEnvironmentVariables -azureEnv $azureEnv -scriptDirectory $PSScriptRoot
}

function ConfirmPrompt {
    param (
        [string]$message
    )

    Write-Host @"
$message (Y/N)
"@ -ForegroundColor Yellow

    $confirm = Read-Host 

    if ($confirm.ToUpper() -ne 'Y') {
        return $false
    }

    return $true
}

function CheckAZCLI {
    # Check if the user is logged into AZ CLI
    Write-Progress -Activity "Checking access via Azure CLI..."
    try {
        $accountInfo = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "You are not logged into Azure CLI. Please run 'az login' to log in." -ForegroundColor Red
            exit 1
        }
        $azureAccount = $accountInfo | ConvertFrom-Json
        # report the current user and subscription
        Write-Host "You are logged in to Azure as '$($azureAccount.user.name)' for the subscription '$($azureAccount.user.name)'" -ForegroundColor Cyan
    } catch {
        Write-Host "An error occurred while checking Azure CLI login status." -ForegroundColor Red
        exit 1
    }
    Write-Progress -Activity "Checking access via Azure CLI..." -Completed
}

function CheckPACCLI {
    Write-Progress -Activity "Checking access via Power Platform CLI..."
    try {
    # Get the environment name that the user is currently authenticated for the Power Apps CLI and check that they are happy with this
    $environment = pac env who --json | ConvertFrom-Json
    $environmentName = $environment.FriendlyName
    $pacUserName = $environment.UserEmail

    Write-Host "You are currently authenticated to the Power Platform CLI as '$pacUserName' for the environment '$environmentName'" -ForegroundColor Cyan
    } catch {
        Write-Host "An error occurred while checking Power Platform CLI login status." -ForegroundColor Red
        exit 1
    }
    Write-Progress -Activity "Checking access via Power Platform CLI..." -Completed

}