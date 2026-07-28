# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
param (
    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,

    [Parameter(Mandatory = $true)]
    [string]$DeploymentRoot,

    [ValidateSet('core', 'portal')]
    [string]$TargetName,

    [string]$SolutionName,

    [switch]$ValidateOnly,

    [switch]$StageAndUpgrade
)

$ErrorActionPreference = 'Stop'

$requiredVariables = @(
    'PAC_DEPLOY_AZURE_TENANT_ID',
    'PAC_DEPLOY_CLIENT_ID',
    'PAC_DEPLOY_CLIENT_SECRET',
    'PAC_DEPLOY_CORE_ENV_URL',
    'PAC_DEPLOY_PORTAL_ENV_URL',
    'PLUGIN_MANAGED_IDENTITY_APP_ID',
    'PAYMENTS_API_CLIENT_SECRET',
    'PAC_DEPLOY_CONFIG'
)

foreach ($name in $requiredVariables) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "$name is not configured."
    }
}

if ([string]::IsNullOrWhiteSpace($env:OVERRIDE_PLUGIN_MANAGED_IDENTITY_ID)) {
    Write-Host 'OVERRIDE_PLUGIN_MANAGED_IDENTITY_ID is not configured. Continuing without override.' -ForegroundColor Yellow
}

if (-not (Test-Path -Path $ArtifactRoot)) {
    throw "Solution package artifact was not found at '$ArtifactRoot'."
}

New-Item -ItemType Directory -Path $DeploymentRoot -Force > $null
$configObj = $env:PAC_DEPLOY_CONFIG | ConvertFrom-Json

if ($ValidateOnly) {
    Write-Host 'CD deployment configuration is valid.' -ForegroundColor Green
    return
}

if ([string]::IsNullOrWhiteSpace($TargetName)) {
    throw 'TargetName is required unless ValidateOnly is specified.'
}

if ([string]::IsNullOrWhiteSpace($SolutionName)) {
    throw 'SolutionName is required unless ValidateOnly is specified.'
}

function Copy-SolutionArtifacts {
    param (
        [string]$SolutionName
    )

    $solutionRoot = Join-Path -Path $DeploymentRoot -ChildPath $SolutionName
    New-Item -ItemType Directory -Path $solutionRoot -Force > $null

    $packages = Get-ChildItem -Path $ArtifactRoot -Filter "$SolutionName*.zip" -ErrorAction Stop
    if ($packages.Count -eq 0) {
        throw "No packages were found for '$SolutionName' in '$ArtifactRoot'."
    }

    foreach ($package in $packages) {
        Copy-Item -Path $package.FullName -Destination $solutionRoot -Force
    }

    return $solutionRoot
}

function Connect-PowerPlatformEnvironment {
    param (
        [string]$EnvironmentUrl
    )

    if ([string]::IsNullOrWhiteSpace($EnvironmentUrl)) {
        throw 'Power Platform environment URL is empty.'
    }

    pac auth create `
        --tenant $env:PAC_DEPLOY_AZURE_TENANT_ID `
        --applicationId $env:PAC_DEPLOY_CLIENT_ID `
        --clientSecret $env:PAC_DEPLOY_CLIENT_SECRET `
        --environment $EnvironmentUrl
    if ($LASTEXITCODE -ne 0) {
        throw "Power Platform authentication failed for '$EnvironmentUrl'."
    }
}

function Set-EnvironmentSettings {
    param (
        [string]$SolutionName
    )

    $environmentSettings = $configObj.$SolutionName.environmentSettings
    if ($null -eq $environmentSettings -or $environmentSettings -eq '') {
        Write-Host 'No environment settings found.' -ForegroundColor Yellow
        return
    }

    foreach ($setting in $environmentSettings.PSObject.Properties) {
        Write-Host "Updating setting '$($setting.Name)'." -ForegroundColor Green
        pac env update-settings --environment $env:PAC_DEPLOY_ENV_URL --name $setting.Name --value $setting.Value
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to update environment setting '$($setting.Name)'."
        }
    }
}

function Get-ConnectionId {
    param (
        [object]$PortalSettings,
        [string]$LogicalName,
        [string]$ApiIdPrefix,
        [string]$DisplayName
    )

    $configuredConnection = $PortalSettings.ConnectionReferences | Where-Object { $_.LogicalName -eq $LogicalName } | Select-Object -First 1
    if ($null -ne $configuredConnection -and -not [string]::IsNullOrWhiteSpace([string]$configuredConnection.ConnectionId)) {
        Write-Host "Using configured connection id for $DisplayName." -ForegroundColor Green
        return [string]$configuredConnection.ConnectionId
    }

    $connectionOutput = pac connection list --environment $env:PAC_DEPLOY_ENV_URL
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list Power Platform connections for '$env:PAC_DEPLOY_ENV_URL'."
    }

    foreach ($line in $connectionOutput) {
        $trimmedLine = ([string]$line).Trim()
        if ($trimmedLine -notmatch '^(?<Id>[a-fA-F0-9]{32})\s+(?<Name>.*?)\s+(?<ApiId>/providers/Microsoft\.PowerApps/apis/\S+)\s+(?<Status>\S+)\s*$') {
            continue
        }

        if ($matches.ApiId.StartsWith($ApiIdPrefix) -and $matches.Status -eq 'Connected') {
            Write-Host "Using connection '$($matches.Name)' for $DisplayName." -ForegroundColor Green
            return $matches.Id
        }
    }

    throw "No connected '$DisplayName' connection was found in '$env:PAC_DEPLOY_ENV_URL'. Create the connection in the Portal environment, then rerun this deployment."
}

function Resolve-PortalConnectionReferences {
    param (
        [string]$SolutionRoot
    )

    $portalSettings = $configObj.ContosoRealEstatePortal.deploymentSettings
    if ($null -eq $portalSettings) {
        throw 'PAC_DEPLOY_CONFIG does not contain ContosoRealEstatePortal deployment settings.'
    }

    $connectionIds = @{
        contoso_PortalBotQueries = Get-ConnectionId `
            -PortalSettings $portalSettings `
            -LogicalName 'contoso_PortalBotQueries' `
            -ApiIdPrefix '/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps' `
            -DisplayName 'Dataverse'
        contoso_StripeAPI = Get-ConnectionId `
            -PortalSettings $portalSettings `
            -LogicalName 'contoso_StripeAPI' `
            -ApiIdPrefix '/providers/Microsoft.PowerApps/apis/shared_contoso-5fcontoso-20stripe-20api' `
            -DisplayName 'Contoso Stripe API'
    }

    pac connection update `
        --environment $env:PAC_DEPLOY_ENV_URL `
        --tenant-id $env:PAC_DEPLOY_AZURE_TENANT_ID `
        --connection-id $connectionIds.contoso_StripeAPI `
        --application-id $env:PLUGIN_MANAGED_IDENTITY_APP_ID `
        --client-secret $env:PAYMENTS_API_CLIENT_SECRET
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to update the Contoso Stripe API connection with the Payments API client secret.'
    }

    foreach ($connectionReference in $portalSettings.ConnectionReferences) {
        if ($connectionIds.ContainsKey($connectionReference.LogicalName)) {
            $connectionReference.ConnectionId = $connectionIds[$connectionReference.LogicalName]
        }
    }

    $portalSettings | ConvertTo-Json -Depth 100 | Out-File -FilePath (Join-Path -Path $SolutionRoot -ChildPath 'deployment_settings.json') -Encoding UTF8
}

function Invoke-DeploymentSettingsInjection {
    param (
        [string]$SolutionName,
        [string]$ManagedPackagePath
    )

    if ($SolutionName -ne 'ContosoRealEstateCore' -and $SolutionName -ne 'ContosoRealEstatePortal') {
        return
    }

    $scriptArguments = @{
        solutionFilePath = $ManagedPackagePath
        pluginManagedIdentityAppId = $env:PLUGIN_MANAGED_IDENTITY_APP_ID
        tenantId = $env:PAC_DEPLOY_AZURE_TENANT_ID
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OVERRIDE_PLUGIN_MANAGED_IDENTITY_ID)) {
        $scriptArguments.overridePluginManagedIdentityId = $env:OVERRIDE_PLUGIN_MANAGED_IDENTITY_ID
    }

    & './src/core/solution/deployment-scripts/inject-configuration-into-solution.ps1' @scriptArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment settings injection failed for '$SolutionName'."
    }
}

function Import-SolutionDataFiles {
    param (
        [string]$SolutionName,
        [string]$SolutionRoot
    )

    $dataFiles = $configObj.$SolutionName.data
    if ($null -eq $dataFiles -or $dataFiles -eq '') {
        Write-Host 'No data files found.' -ForegroundColor Yellow
        return
    }

    foreach ($file in $dataFiles) {
        $releaseAssetPath = (Join-Path -Path $SolutionRoot -ChildPath $file).Trim()
        $repositoryDataPath = (Join-Path -Path 'src/core/data' -ChildPath $file).Trim()
        $filePath = if (Test-Path -Path $releaseAssetPath) {
            $releaseAssetPath
        }
        elseif (Test-Path -Path $repositoryDataPath) {
            $repositoryDataPath
        }
        else {
            throw "Data import file '$file' was not found at '$releaseAssetPath' or '$repositoryDataPath'."
        }

        Write-Host "Importing data from $filePath."
        pac data import --environment $env:PAC_DEPLOY_ENV_URL --data $filePath
        if ($LASTEXITCODE -ne 0) {
            throw "Data import failed for '$filePath'."
        }
    }
}

function Deploy-Solution {
    param (
        [string]$TargetName,
        [string]$SolutionName
    )

    Write-Host "Deploying $TargetName / $SolutionName" -ForegroundColor Cyan
    $env:PAC_DEPLOY_ENV_URL = if ($TargetName -eq 'portal') { $env:PAC_DEPLOY_PORTAL_ENV_URL } else { $env:PAC_DEPLOY_CORE_ENV_URL }
    $solutionRoot = Copy-SolutionArtifacts -SolutionName $SolutionName
    $managedPackagePath = Join-Path -Path $solutionRoot -ChildPath "${SolutionName}_managed.zip"
    if (-not (Test-Path -Path $managedPackagePath)) {
        throw "Managed solution package was not found: '$managedPackagePath'."
    }

    Invoke-DeploymentSettingsInjection -SolutionName $SolutionName -ManagedPackagePath $managedPackagePath
    Connect-PowerPlatformEnvironment -EnvironmentUrl $env:PAC_DEPLOY_ENV_URL
    Set-EnvironmentSettings -SolutionName $SolutionName

    if ($SolutionName -eq 'ContosoRealEstatePortal') {
        Resolve-PortalConnectionReferences -SolutionRoot $solutionRoot
    }

    $deploymentSettings = $configObj.$SolutionName.deploymentSettings
    $settingsFilePath = Join-Path -Path $solutionRoot -ChildPath 'deployment_settings.json'
    if ($null -ne $deploymentSettings -and $deploymentSettings -ne '' -and -not (Test-Path -Path $settingsFilePath)) {
        $deploymentSettings | ConvertTo-Json -Depth 100 | Out-File -FilePath $settingsFilePath -Encoding UTF8
    }

    $arguments = @('solution', 'import', '--environment', $env:PAC_DEPLOY_ENV_URL, '--activate-plugins', '--skip-lower-version', '--async', '--path', $managedPackagePath)
    if ($StageAndUpgrade) {
        $arguments += '--stage-and-upgrade'
    }
    if (Test-Path -Path $settingsFilePath) {
        $arguments += @('--settings-file', $settingsFilePath)
    }

    Write-Host "pac $($arguments -join ' ')"
    & pac @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Solution import failed for '$SolutionName'."
    }

    Import-SolutionDataFiles -SolutionName $SolutionName -SolutionRoot $solutionRoot
}

Deploy-Solution -TargetName $TargetName -SolutionName $SolutionName