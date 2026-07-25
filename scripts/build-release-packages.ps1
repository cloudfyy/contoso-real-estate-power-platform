# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
param (
    [ValidateSet('Controls', 'Core', 'Portal', 'All')]
    [string[]]$Solution = @('All'),
    [switch]$UseExistingPackages,
    [switch]$VerifyOnly,
    [switch]$Clean,
    [switch]$CleanNodeModules
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\solution-packages.ps1"

function Invoke-DotNetBuild {
    param (
        [string]$ProjectPath
    )

    $arguments = @('build', '-c', 'Release', $ProjectPath)

    Write-Host "dotnet $($arguments -join ' ')" -ForegroundColor Cyan
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed for '$ProjectPath'."
    }
}

function Remove-PathIfExists {
    param (
        [string]$Path
    )

    if (Test-Path -Path $Path) {
        Write-Host "Removing '$Path'" -ForegroundColor Yellow
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Host "Unable to fully remove '$Path'. Continuing. $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Clear-SolutionBuildOutputs {
    param (
        [hashtable]$Definition,
        [string]$RepoRoot,
        [switch]$IncludeNodeModules
    )

    foreach ($relativePath in $Definition.CleanPaths) {
        Remove-PathIfExists -Path (Join-Path -Path $RepoRoot -ChildPath $relativePath)
    }

    if ($IncludeNodeModules) {
        foreach ($relativePath in $Definition.NodeModulePaths) {
            Remove-PathIfExists -Path (Join-Path -Path $RepoRoot -ChildPath $relativePath)
        }
    }
}

function Invoke-SolutionBuild {
    param (
        [hashtable]$Definition,
        [string]$RepoRoot,
        [switch]$UseExistingPackages,
        [switch]$VerifyOnly
    )

    $projectPath = Join-Path -Path $RepoRoot -ChildPath $Definition.ProjectPath
    $solutionXmlPath = Join-Path -Path $RepoRoot -ChildPath $Definition.SolutionXmlPath
    $version = Get-SolutionVersion -SolutionXmlPath $solutionXmlPath

    if ($UseExistingPackages -and -not $VerifyOnly) {
        try {
            foreach ($package in $Definition.Packages) {
                $packagePath = Join-Path -Path $RepoRoot -ChildPath $package.Path
                Test-SolutionPackage `
                    -PackagePath $packagePath `
                    -ExpectedUniqueName $Definition.UniqueName `
                    -ExpectedVersion $version `
                    -ExpectedManaged $package.Managed `
                    -RequiredEntries $Definition.RequiredEntries
            }

            Write-Host "Existing $($Definition.Name) packages are valid. Skipping build." -ForegroundColor Green
            return
        }
        catch {
            Write-Host "Existing $($Definition.Name) packages are missing or invalid. Rebuilding. $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if (-not $VerifyOnly) {
        Invoke-DotNetBuild -ProjectPath $projectPath
    }

    foreach ($package in $Definition.Packages) {
        $packagePath = Join-Path -Path $RepoRoot -ChildPath $package.Path
        Test-SolutionPackage `
            -PackagePath $packagePath `
            -ExpectedUniqueName $Definition.UniqueName `
            -ExpectedVersion $version `
            -ExpectedManaged $package.Managed `
            -RequiredEntries $Definition.RequiredEntries
    }
}

$repoRoot = Get-RepositoryRoot
Set-Location -Path $repoRoot

if ($VerifyOnly -and ($Clean -or $CleanNodeModules)) {
    throw 'Do not combine -VerifyOnly with -Clean or -CleanNodeModules.'
}

if ($Clean -and $UseExistingPackages) {
    Write-Host '-Clean was specified, so -UseExistingPackages will be ignored.' -ForegroundColor Yellow
    $UseExistingPackages = $false
}

$selectedDefinitions = @(Resolve-SolutionPackageDefinitions -Solution $Solution)
$solutionTimings = @()
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($definition in $selectedDefinitions) {
    Write-Host "`n== $($definition.Name) ==" -ForegroundColor White
    $solutionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Clean -or $CleanNodeModules) {
            Clear-SolutionBuildOutputs `
                -Definition $definition `
                -RepoRoot $repoRoot `
                -IncludeNodeModules:$CleanNodeModules
        }

        Invoke-SolutionBuild `
            -Definition $definition `
            -RepoRoot $repoRoot `
            -UseExistingPackages:$UseExistingPackages `
            -VerifyOnly:$VerifyOnly
    }
    finally {
        $solutionStopwatch.Stop()
        $solutionTimings += [PSCustomObject]@{
            Solution = $definition.Name
            Seconds = [math]::Round($solutionStopwatch.Elapsed.TotalSeconds, 2)
        }
    }
}

$totalStopwatch.Stop()

Write-Host "`nBuild timing summary" -ForegroundColor White
$solutionTimings | Format-Table -AutoSize
Write-Host ("Total: {0:n2} seconds" -f $totalStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host "`nSolution package build complete." -ForegroundColor Green
