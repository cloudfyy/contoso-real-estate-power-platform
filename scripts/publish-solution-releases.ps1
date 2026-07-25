# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [ValidateSet('Controls', 'Core', 'Portal', 'All')]
    [string[]]$Solution = @('All'),
    [string]$Repository,
    [string]$Remote = 'origin',
    [string]$Branch = 'main',
    [switch]$Clean,
    [switch]$CleanNodeModules,
    [switch]$IsolatedWorkspace,
    [switch]$SkipPush
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common\solution-packages.ps1"

function Assert-CommandSucceeded {
    param (
        [string]$CommandDescription
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$CommandDescription failed with exit code $LASTEXITCODE."
    }
}

function Assert-CleanGitWorktree {
    $status = git status --porcelain
    if (-not [string]::IsNullOrWhiteSpace(($status -join ''))) {
        throw "The git worktree is not clean. Commit, stash, or discard changes before publishing releases.`n$status"
    }
}

function Test-ReleaseExists {
    param (
        [string]$RepositoryName,
        [string]$TagName
    )

    gh release view $TagName --repo $RepositoryName --json tagName *> $null
    return $LASTEXITCODE -eq 0
}

function Invoke-ExternalCommand {
    param (
        [string]$CommandDescription,
        [scriptblock]$ScriptBlock
    )

    & $ScriptBlock
    Assert-CommandSucceeded -CommandDescription $CommandDescription
}

$repoRoot = Get-RepositoryRoot
Set-Location -Path $repoRoot

if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = Get-GitHubRepositoryName -RemoteName $Remote
}

$selectedDefinitions = @(Resolve-SolutionPackageDefinitions -Solution $Solution)
$releasePlan = foreach ($definition in $selectedDefinitions) {
    $solutionXmlPath = Join-Path -Path $repoRoot -ChildPath $definition.SolutionXmlPath
    $currentVersion = Get-SolutionVersion -SolutionXmlPath $solutionXmlPath
    $nextVersion = Get-NextSolutionVersion -CurrentVersion $currentVersion
    $releaseVersion = Get-ReleaseVersion -SolutionVersion $nextVersion
    $tagName = "v$releaseVersion-$($definition.ReleaseName)"

    [pscustomobject]@{
        Name = $definition.Name
        UniqueName = $definition.UniqueName
        CurrentVersion = $currentVersion
        NextVersion = $nextVersion
        ReleaseVersion = $releaseVersion
        TagName = $tagName
        Title = $tagName
        SolutionXmlPath = $solutionXmlPath
        BuildSolution = $definition.Name
        PackagePaths = @($definition.Packages | ForEach-Object { Join-Path -Path $repoRoot -ChildPath $_.Path })
    }
}

Write-Host "Repository: $Repository" -ForegroundColor Cyan
Write-Host "Branch: $Branch" -ForegroundColor Cyan
Write-Host 'Release plan:' -ForegroundColor Cyan
$releasePlan | ForEach-Object {
    Write-Host "  $($_.Name): $($_.CurrentVersion) -> $($_.NextVersion), tag $($_.TagName)" -ForegroundColor White
}

foreach ($release in $releasePlan) {
    if (Test-ReleaseExists -RepositoryName $Repository -TagName $release.TagName) {
        throw "Release '$($release.TagName)' already exists in '$Repository'."
    }
}

if ($PSCmdlet.ShouldProcess($Repository, 'publish solution releases')) {
    Assert-CleanGitWorktree

    $versionFiles = @($releasePlan | ForEach-Object { $_.SolutionXmlPath })
    $versionFilesCommitted = $false

    try {
        foreach ($release in $releasePlan) {
            Write-Host "Setting $($release.Name) solution version to $($release.NextVersion)." -ForegroundColor Cyan
            Set-SolutionVersion -SolutionXmlPath $release.SolutionXmlPath -Version $release.NextVersion
        }

        $buildArguments = @{
            Solution = @($releasePlan.BuildSolution)
        }
        if ($Clean) {
            $buildArguments.Clean = $true
        }
        if ($CleanNodeModules) {
            $buildArguments.CleanNodeModules = $true
        }
        if ($IsolatedWorkspace) {
            $buildArguments.IsolatedWorkspace = $true
        }

        Invoke-ExternalCommand -CommandDescription 'Build release packages' -ScriptBlock {
            & (Join-Path -Path $repoRoot -ChildPath 'scripts\build-release-packages.ps1') @buildArguments
        }

        Invoke-ExternalCommand -CommandDescription 'Stage release version files' -ScriptBlock {
            git add @versionFiles
        }

        Invoke-ExternalCommand -CommandDescription 'Commit release version files' -ScriptBlock {
            git commit -m 'Bump solution versions for release'
        }
        $versionFilesCommitted = $true

        if (-not $SkipPush) {
            Invoke-ExternalCommand -CommandDescription "Push $Remote $Branch" -ScriptBlock {
                git push $Remote $Branch
            }
        }

        foreach ($release in $releasePlan) {
            $notes = "$($release.UniqueName) solution package release $($release.ReleaseVersion)."
            $assetArguments = @($release.PackagePaths)
            Invoke-ExternalCommand -CommandDescription "Create GitHub release $($release.TagName)" -ScriptBlock {
                gh release create $release.TagName @assetArguments --repo $Repository --target $Branch --title $release.Title --notes $notes
            }
        }

        Write-Host 'Release publishing complete.' -ForegroundColor Green
    }
    catch {
        if (-not $versionFilesCommitted) {
            Write-Host 'Release publishing failed before version files were committed. Restoring original solution versions.' -ForegroundColor Yellow
            git restore --staged -- $versionFiles *> $null
            git restore --worktree -- $versionFiles *> $null
        }

        throw
    }
}
