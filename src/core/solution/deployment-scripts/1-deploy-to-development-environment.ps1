# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
param (
    [string]$azureEnv
)

function Assert-NativeCommandSucceeded {
    param (
        [string]$Operation
    )

    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Host "$Operation failed. Stopping deployment." -ForegroundColor Red
    exit $LASTEXITCODE
}

$solutionName = "ContosoRealEstateCore"
Write-Host "This script will deploy the $solutionName solution to your development environment." -ForegroundColor White

# -----------------------------------------------------------------------
# Import the environment variables
Set-Location -Path $PSScriptRoot
$repoRoot =  Join-Path -Path $PSScriptRoot -ChildPath "/../../../../"
# Resolve to an absolute path
$repoRoot = (Get-Item -Path $repoRoot).FullName

. "$repoRoot/src/core/solution/deployment-scripts/function-get-environment-variables.ps1"
$releaseRepositoryName = GetGitHubRepositoryName -remoteNames @('origin')
$envVars = GetEnvironmentVariables -azureEnv $azureEnv
$azureEnv = $envVars.AZURE_ENV_NAME

$sourceFolder = Join-Path -Path $PSScriptRoot -ChildPath "../$solutionName"
$tempReleaseFolder = Join-Path -Path $repoRoot -ChildPath "/temp_releases"

$dependencies = @(
    @{
        AssetName = 'ContosoRealEstateCustomControls_managed.zip'
        BuildSolution = 'Controls'
        LocalAssetPath = Join-Path -Path $repoRoot -ChildPath 'src/controls/solution/ContosoRealEstateCustomControls/bin/ContosoRealEstateCustomControls_managed.zip'
    }
)

$solutionPackageSource = InitializeSolutionDependencyAssets `
    -repositoryName $releaseRepositoryName `
    -outputFolder $tempReleaseFolder `
    -repoRoot $repoRoot `
    -dependencies $dependencies

if ($solutionPackageSource -eq 'GitHubRelease') {
    SaveGitHubReleaseAsset `
        -repositoryName $releaseRepositoryName `
        -assetName "ContosoRealEstateCore.zip" `
        -outputFolder $tempReleaseFolder > $null
    $solutionPackagePath = Join-Path -Path $tempReleaseFolder -ChildPath "ContosoRealEstateCore.zip"
}
else {
    InvokeSolutionPackageBuild -solutionFolder $sourceFolder
    $solutionPackagePath = Join-Path -Path $sourceFolder -ChildPath "bin/$solutionName.zip"
}

$solutionPackageInfo = GetSolutionPackageInfo -packagePath $solutionPackagePath
Write-Host "Current solution package version: $($solutionPackageInfo.UniqueName) $($solutionPackageInfo.Version)" -ForegroundColor Cyan

# Create core deployment settings file
Write-Host "Creating deployment settings for " -ForegroundColor Green
. "$repoRoot/src/core/solution/deployment-scripts/generate-deployment-settings.ps1" -azureEnv $azureEnv

CheckPACCLI

# Get the environment name that the user is currently authenticated for the Power Apps CLI and check that they are happy with this
$environment = pac env who --json | ConvertFrom-Json
$environmentName = $environment.FriendlyName
$azureEnv = $envVars.AZURE_ENV_NAME

if (-not (ConfirmPrompt -message "Are you sure you want to deploy to the environment ${environmentName}?")) {
    Write-Host "Exiting" -ForegroundColor Yellow
    exit
}

# Enable PCF controls in Canvas Apps
pac env update-settings --name "iscustomcontrolsincanvasappsenabled" --value true
Assert-NativeCommandSucceeded -Operation "Enabling PCF controls in Canvas Apps"

# Enable JavaScript attachments for the portal
pac env update-settings --name "blockedattachments" --value "ade;adp;app;asa;ashx;asmx;asp;bas;bat;cdx;cer;chm;class;cmd;com;config;cpl;crt;csh;dll;exe;fxp;hlp;hta;htr;htw;ida;idc;idq;inf;ins;isp;its;jar;jse;ksh;lnk;mad;maf;mag;mam;maq;mar;mas;mat;mau;mav;maw;mda;mdb;mde;mdt;mdw;mdz;msc;msh;msh1;msh1xml;msh2;msh2xml;mshxml;msi;msp;mst;ops;pcd;pif;prf;prg;printer;pst;reg;rem;scf;scr;sct;shb;shs;shtm;shtml;soap;stm;tmp;url;vb;vbe;vbs;vsmacros;vss;vst;vsw;ws;wsc;wsf;wsh"
Assert-NativeCommandSucceeded -Operation "Enabling JavaScript attachments for the portal"


# Deploy the dependencies
Write-Host "Deploying 'ContosoRealEstateCustomControls_managed.zip' to '$environmentName'" -ForegroundColor Green
pac solution import -p "$tempReleaseFolder/ContosoRealEstateCustomControls_managed.zip" -a
Assert-NativeCommandSucceeded -Operation "Importing solution dependency 'ContosoRealEstateCustomControls_managed.zip'"

# Deploy the development unmanaged solution
Write-Host "Deploying solution '$solutionName' to '$environmentName'" -ForegroundColor Green
pac solution import -p $solutionPackagePath -a -ap -pc --settings-file "$repoRoot/src/core/solution/deployment-scripts/temp_deploymentSettings_$azureEnv.json"
Assert-NativeCommandSucceeded -Operation "Importing solution '$solutionName'"

# Import test data
Write-Host "Importing test data" -ForegroundColor Green
pac data import -d "$repoRoot/src/core/data/reference-data.zip"
Assert-NativeCommandSucceeded -Operation "Importing reference data"
pac data import -d "$repoRoot/src/core/data/sample-data.zip"
Assert-NativeCommandSucceeded -Operation "Importing sample data"

Write-Host "Complete" -ForegroundColor Green
