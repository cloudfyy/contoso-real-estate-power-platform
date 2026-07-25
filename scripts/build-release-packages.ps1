# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
param (
    [ValidateSet('Controls', 'Core', 'Portal', 'All')]
    [string[]]$Solution = @('All'),
    [switch]$UseExistingPackages,
    [switch]$VerifyOnly,
    [switch]$Clean,
    [switch]$CleanNodeModules,
    [switch]$IsolatedWorkspace,
    [switch]$CleanIsolatedCache
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
$buildRepoRoot = $repoRoot
$isolatedWorkspaceRoot = $null
$isolatedCacheRoot = $null
$isolatedRootDrive = Get-LargestFreeFileSystemRoot
$isolatedCacheRoot = Join-Path -Path $isolatedRootDrive -ChildPath 'cre-build-cache'

if ($CleanIsolatedCache) {
    Write-Host "Isolated node_modules cache root: $isolatedCacheRoot" -ForegroundColor Cyan
    Clear-IsolatedNodeModuleCache -CacheRoot $isolatedCacheRoot
    if (-not $IsolatedWorkspace) {
        return
    }
}

if ($IsolatedWorkspace) {
    if ($UseExistingPackages -or $VerifyOnly) {
        throw 'Do not combine -IsolatedWorkspace with -UseExistingPackages or -VerifyOnly.'
    }

    $isolatedWorkspaceRoot = Join-Path -Path $isolatedRootDrive -ChildPath "cre-build-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    Write-Host "Isolated workspace root: $isolatedWorkspaceRoot" -ForegroundColor Cyan
    Write-Host "Isolated node_modules cache root: $isolatedCacheRoot" -ForegroundColor Cyan

    Copy-RepositoryToIsolatedWorkspace -SourceRoot $repoRoot -DestinationRoot $isolatedWorkspaceRoot
    Restore-IsolatedNodeModuleCache -Definitions $selectedDefinitions -CacheRoot $isolatedCacheRoot -WorkspaceRoot $isolatedWorkspaceRoot
    $buildRepoRoot = $isolatedWorkspaceRoot
}

$solutionTimings = @()
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    foreach ($definition in $selectedDefinitions) {
        Write-Host "`n== $($definition.Name) ==" -ForegroundColor White
        $solutionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            if ($Clean -or $CleanNodeModules) {
                Clear-SolutionBuildOutputs `
                    -Definition $definition `
                    -RepoRoot $buildRepoRoot `
                    -IncludeNodeModules:$CleanNodeModules
            }

            Invoke-SolutionBuild `
                -Definition $definition `
                -RepoRoot $buildRepoRoot `
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

    if ($IsolatedWorkspace) {
        Save-IsolatedNodeModuleCache -Definitions $selectedDefinitions -CacheRoot $isolatedCacheRoot -WorkspaceRoot $buildRepoRoot
        Copy-SolutionPackagesToRepository -Definitions $selectedDefinitions -SourceRoot $buildRepoRoot -DestinationRoot $repoRoot
    }
}
finally {
    if ($IsolatedWorkspace -and -not [string]::IsNullOrWhiteSpace($isolatedWorkspaceRoot) -and (Test-Path -Path $isolatedWorkspaceRoot)) {
        Remove-IsolatedOwnedPath -Path $isolatedWorkspaceRoot -Purpose 'isolated workspace' > $null
    }
}

$totalStopwatch.Stop()

Write-Host "`nBuild timing summary" -ForegroundColor White
$solutionTimings | Format-Table -AutoSize
Write-Host ("Total: {0:n2} seconds" -f $totalStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host "`nSolution package build complete." -ForegroundColor Green
