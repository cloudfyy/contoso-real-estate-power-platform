# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
param (
    [ValidateSet('Controls', 'Core', 'Portal', 'All')]
    [string[]]$Solution = @('All'),
    [switch]$UseExistingPackages,
    [switch]$VerifyOnly,
    [switch]$Clean,
    [switch]$CleanNodeModules,
    [switch]$IsolatedWorkspace
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\solution-packages.ps1"

function Copy-RepositoryToIsolatedWorkspace {
    param (
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    New-Item -ItemType Directory -Path $DestinationRoot -Force > $null

    $excludeDirectories = @(
        '.git',
        '.vs',
        'bin',
        'obj',
        'Metadata',
        'node_modules',
        'SolutionPackager',
        'SolutionPackagerLogs',
        'temp_releases',
        'temp_tools'
    )
    $excludeFiles = @('*.binlog')
    $arguments = @(
        $SourceRoot,
        $DestinationRoot,
        '/MIR',
        '/R:3',
        '/W:2',
        '/NFL',
        '/NDL',
        '/NP',
        '/NJH',
        '/NJS',
        '/XD'
    ) + $excludeDirectories + @('/XF') + $excludeFiles

    Write-Host "Copying repository to isolated workspace '$DestinationRoot'" -ForegroundColor Cyan
    & robocopy @arguments
    if ($LASTEXITCODE -gt 7) {
        throw "Failed to copy repository to isolated workspace. robocopy exit code: $LASTEXITCODE."
    }
}

function Copy-SolutionPackagesToRepository {
    param (
        [array]$Definitions,
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    foreach ($definition in $Definitions) {
        foreach ($package in $definition.Packages) {
            $sourcePath = Join-Path -Path $SourceRoot -ChildPath $package.Path
            $destinationPath = Join-Path -Path $DestinationRoot -ChildPath $package.Path
            if (-not (Test-Path -Path $sourcePath)) {
                throw "Expected isolated package was not found: '$sourcePath'."
            }

            New-Item -ItemType Directory -Path (Split-Path -Path $destinationPath -Parent) -Force > $null
            Copy-Item -Path $sourcePath -Destination $destinationPath -Force
            Write-Host "Copied '$sourcePath' to '$destinationPath'" -ForegroundColor Green
        }
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
$buildRepoRoot = $repoRoot
$isolatedWorkspaceRoot = $null

if ($IsolatedWorkspace) {
    if ($UseExistingPackages -or $VerifyOnly) {
        throw 'Do not combine -IsolatedWorkspace with -UseExistingPackages or -VerifyOnly.'
    }

    $isolatedWorkspaceRoot = "C:\cre-build-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    Copy-RepositoryToIsolatedWorkspace -SourceRoot $repoRoot -DestinationRoot $isolatedWorkspaceRoot
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
        Copy-SolutionPackagesToRepository -Definitions $selectedDefinitions -SourceRoot $buildRepoRoot -DestinationRoot $repoRoot
    }
}
finally {
    if ($IsolatedWorkspace -and -not [string]::IsNullOrWhiteSpace($isolatedWorkspaceRoot) -and (Test-Path -Path $isolatedWorkspaceRoot)) {
        Remove-Item -Path $isolatedWorkspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$totalStopwatch.Stop()

Write-Host "`nBuild timing summary" -ForegroundColor White
$solutionTimings | Format-Table -AutoSize
Write-Host ("Total: {0:n2} seconds" -f $totalStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host "`nSolution package build complete." -ForegroundColor Green
