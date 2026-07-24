# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
function GetRepositoryEnvironmentVariables {
    param (
        [string]$azureEnv,
        [string]$scriptDirectory = $PSScriptRoot,
        [bool]$outputVariables = $false
    )

    $envFile = Join-Path -Path $scriptDirectory -ChildPath '.env'
    if (Test-Path -Path $envFile) {
        if ($azureEnv -eq "") {
            Write-Host "Reading from '.env' at '${envFile}'. Remove this to use the .env file in the .azure folder"
        }
        $envFolder = $envFile
    }
    else {
        $targetFolderName = ".azure"
        $currentDirectory = $scriptDirectory

        while ($currentDirectory -ne [System.IO.Directory]::GetDirectoryRoot($currentDirectory)) {
            if (Test-Path -Path (Join-Path -Path $currentDirectory -ChildPath $targetFolderName)) {
                Write-Host "Found $targetFolderName in $currentDirectory" -ForegroundColor Green
                break
            }

            $currentDirectory = Get-Item -Path (Join-Path -Path $currentDirectory -ChildPath "..")
        }

        if ($currentDirectory -eq [System.IO.Directory]::GetDirectoryRoot($currentDirectory)) {
            Write-Host "$targetFolderName not found in any parent directories." -ForegroundColor Red
            exit
        }

        $azureFolderPath = Join-Path -Path $currentDirectory -ChildPath ".azure"
        if (-not (Test-Path -Path $azureFolderPath)) {
            Write-Host "The .azure folder does not exist. Run azd up first" -ForegroundColor Red
            exit
        }

        $folders = Get-ChildItem -Path $azureFolderPath -Directory
        if ($azureEnv -eq "") {
            $defaultFolderName = GetDefaultAzureEnvironmentName -azureFolderPath $azureFolderPath -folders $folders
            $folders | ForEach-Object {
                $defaultMarker = if ($_.Name -eq $defaultFolderName) { ' (default)' } else { '' }
                Write-Host "[$($_.Name)]$defaultMarker"
            }

            $selectedFolderName = Read-Host "Enter the azure environment configuration [$defaultFolderName]"
            if ([string]::IsNullOrWhiteSpace($selectedFolderName)) {
                $selectedFolderName = $defaultFolderName
            }

            $selectedFolderName = $selectedFolderName -replace "\[|\]", ""
        }
        else {
            $selectedFolderName = $azureEnv
        }

        $selectedFolder = $folders | Where-Object { $_.Name -eq $selectedFolderName }
        if ($null -eq $selectedFolder) {
            Write-Host "Invalid .azure environment '$selectedFolderName'" -ForegroundColor Red
            exit
        }

        $environment = $selectedFolder.Name

        Write-Host "Reading from '$environment/.env'"
        $envFolder = Join-Path -Path $azureFolderPath -ChildPath "$environment/.env"

        if (-not (Test-Path -Path $envFolder)) {
            Write-Host "The file '$environment/.env' does not exist" -ForegroundColor Red
            exit
        }
    }

    $envFile = Get-Content -Path $envFolder
    $envVars = New-Object PSObject
    $envFile | ForEach-Object {
        if ($_ -match '^(.*)="(.*)"$') {
            $name = $matches[1].ToUpper()
            $value = $matches[2]
            $envVars | Add-Member -MemberType NoteProperty -Name $name -Value $value
            if ($outputVariables) {
                Write-Host " $name = '$value'" -ForegroundColor Gray
            }
        }
    }

    return $envVars
}

function GetDefaultAzureEnvironmentName {
    param (
        [string]$azureFolderPath,
        [array]$folders
    )

    $configFile = Join-Path -Path $azureFolderPath -ChildPath 'config.json'
    if (Test-Path -Path $configFile) {
        try {
            $config = Get-Content -Path $configFile -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($config.defaultEnvironment)) {
                $configuredDefault = $folders | Where-Object { $_.Name -eq $config.defaultEnvironment } | Select-Object -First 1
                if ($null -ne $configuredDefault) {
                    return $configuredDefault.Name
                }
            }
        }
        catch {
            Write-Host "Unable to read azd default environment from '$configFile'. Falling back to the first environment folder." -ForegroundColor Yellow
        }
    }

    $firstFolder = $folders | Select-Object -First 1
    return $firstFolder.Name
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
    Write-Progress -Activity "Checking access via Azure CLI..."
    try {
        $accountInfo = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "You are not logged into Azure CLI. Please run 'az login' to log in." -ForegroundColor Red
            exit 1
        }

        $azureAccount = $accountInfo | ConvertFrom-Json
        Write-Host "You are logged in to Azure as '$($azureAccount.user.name)' for the subscription '$($azureAccount.user.name)'" -ForegroundColor Cyan
    }
    catch {
        Write-Host "An error occurred while checking Azure CLI login status." -ForegroundColor Red
        exit 1
    }
    Write-Progress -Activity "Checking access via Azure CLI..." -Completed
}

function CheckPACCLI {
    Write-Progress -Activity "Checking access via Power Platform CLI..."
    try {
        $environment = pac env who --json | ConvertFrom-Json
        $environmentName = $environment.FriendlyName
        $pacUserName = $environment.UserEmail

        Write-Host "You are currently authenticated to the Power Platform CLI as '$pacUserName' for the environment '$environmentName'" -ForegroundColor Cyan
    }
    catch {
        Write-Host "An error occurred while checking Power Platform CLI login status." -ForegroundColor Red
        exit 1
    }
    Write-Progress -Activity "Checking access via Power Platform CLI..." -Completed
}