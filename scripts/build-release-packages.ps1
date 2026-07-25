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
