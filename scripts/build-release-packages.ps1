# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
param (
    [ValidateSet('Controls', 'Core', 'Portal', 'All')]
    [string[]]$Solution = @('All'),
    [switch]$SkipProjectReferences,
    [switch]$UseExistingPackages,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

function Get-RepositoryRoot {
    $currentDirectory = $PSScriptRoot
    while ($currentDirectory -ne [System.IO.Directory]::GetDirectoryRoot($currentDirectory)) {
        if (Test-Path -Path (Join-Path -Path $currentDirectory -ChildPath '.git')) {
            return (Get-Item -Path $currentDirectory).FullName
        }

        $currentDirectory = Split-Path -Path $currentDirectory -Parent
    }

    throw 'Unable to find repository root.'
}

function Get-SolutionVersion {
    param (
        [string]$SolutionXmlPath
    )

    [xml]$solutionXml = Get-Content -Path $SolutionXmlPath -Raw
    return [string]$solutionXml.ImportExportXml.SolutionManifest.Version
}

function Invoke-DotNetBuild {
    param (
        [string]$ProjectPath,
        [switch]$SkipReferences
    )

    $arguments = @('build', '-c', 'Release', $ProjectPath)
    if ($SkipReferences) {
        $arguments += '/p:BuildProjectReferences=false'
    }

    Write-Host "dotnet $($arguments -join ' ')" -ForegroundColor Cyan
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed for '$ProjectPath'."
    }
}

function Repair-PortalReactUiManifest {
    param (
        [string]$RepoRoot
    )

    $sourceManifestPath = Join-Path -Path $RepoRoot -ChildPath 'src\portal\PortalReactUI\PortalReactUI\ControlManifest.Input.xml'
    $outputControlPath = Join-Path -Path $RepoRoot -ChildPath 'src\portal\PortalReactUI\out\controls\PortalReactUI'
    $outputBundlePath = Join-Path -Path $outputControlPath -ChildPath 'bundle.js'
    $outputManifestPath = Join-Path -Path $outputControlPath -ChildPath 'ControlManifest.xml'

    if (Test-Path -Path $outputManifestPath) {
        return
    }

    if (-not (Test-Path -Path $outputBundlePath)) {
        throw "PortalReactUI bundle was not found at '$outputBundlePath'. Build PortalReactUI before packaging with -SkipProjectReferences."
    }

    if (-not (Test-Path -Path $sourceManifestPath)) {
        throw "PortalReactUI source manifest was not found at '$sourceManifestPath'."
    }

    Write-Host "PortalReactUI output manifest is missing. Copying ControlManifest.Input.xml to '$outputManifestPath'." -ForegroundColor Yellow
    Copy-Item -Path $sourceManifestPath -Destination $outputManifestPath -Force
}

function Test-PortalManifestError {
    param (
        [string]$RepoRoot
    )

    $outputControlPath = Join-Path -Path $RepoRoot -ChildPath 'src\portal\PortalReactUI\out\controls\PortalReactUI'
    $outputBundlePath = Join-Path -Path $outputControlPath -ChildPath 'bundle.js'
    $outputManifestPath = Join-Path -Path $outputControlPath -ChildPath 'ControlManifest.xml'

    return (Test-Path -Path $outputBundlePath) -and -not (Test-Path -Path $outputManifestPath)
}

function Test-SolutionPackage {
    param (
        [string]$PackagePath,
        [string]$ExpectedUniqueName,
        [string]$ExpectedVersion,
        [int]$ExpectedManaged,
        [string[]]$RequiredEntries = @()
    )

    if (-not (Test-Path -Path $PackagePath)) {
        throw "Expected package was not found: '$PackagePath'."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -Path $PackagePath))
    try {
        $solutionEntry = $zip.Entries | Where-Object FullName -eq 'solution.xml' | Select-Object -First 1
        if ($null -eq $solutionEntry) {
            throw "Package '$PackagePath' does not contain solution.xml."
        }

        $reader = [System.IO.StreamReader]::new($solutionEntry.Open())
        try {
            [xml]$solutionXml = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $manifest = $solutionXml.ImportExportXml.SolutionManifest
        if ($manifest.UniqueName -ne $ExpectedUniqueName) {
            throw "Package '$PackagePath' has solution '$($manifest.UniqueName)', expected '$ExpectedUniqueName'."
        }

        if ($manifest.Version -ne $ExpectedVersion) {
            throw "Package '$PackagePath' has version '$($manifest.Version)', expected '$ExpectedVersion'."
        }

        if ([int]$manifest.Managed -ne $ExpectedManaged) {
            throw "Package '$PackagePath' has Managed='$($manifest.Managed)', expected '$ExpectedManaged'."
        }

        $entryNames = @($zip.Entries | Select-Object -ExpandProperty FullName)
        foreach ($requiredEntry in $RequiredEntries) {
            if ($entryNames -notcontains $requiredEntry) {
                throw "Package '$PackagePath' does not contain required entry '$requiredEntry'."
            }
        }

        $file = Get-Item -Path $PackagePath
        Write-Host "Verified $PackagePath -> $($manifest.UniqueName) $($manifest.Version) managed=$($manifest.Managed) size=$($file.Length)" -ForegroundColor Green
    }
    finally {
        $zip.Dispose()
    }
}

function Invoke-SolutionBuild {
    param (
        [hashtable]$Definition,
        [string]$RepoRoot,
        [switch]$SkipReferences,
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
        if ($Definition.Name -eq 'Portal' -and $SkipReferences) {
            Repair-PortalReactUiManifest -RepoRoot $RepoRoot
        }

        try {
            Invoke-DotNetBuild -ProjectPath $projectPath -SkipReferences:$SkipReferences
        }
        catch {
            if ($Definition.Name -eq 'Portal' -and -not $SkipReferences -and (Test-PortalManifestError -RepoRoot $RepoRoot)) {
                Write-Host $_.Exception.Message -ForegroundColor Yellow
                Repair-PortalReactUiManifest -RepoRoot $RepoRoot
                Write-Host 'Retrying portal solution packaging without rebuilding project references.' -ForegroundColor Yellow
                Invoke-DotNetBuild -ProjectPath $projectPath -SkipReferences
            }
            else {
                throw
            }
        }
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

$definitions = @(
    @{
        Name = 'Controls'
        UniqueName = 'ContosoRealEstateCustomControls'
        ProjectPath = 'src\controls\solution\ContosoRealEstateCustomControls\ContosoRealEstateCustomControls.cdsproj'
        SolutionXmlPath = 'src\controls\solution\ContosoRealEstateCustomControls\src\Other\Solution.xml'
        RequiredEntries = @(
            'Controls/contoso_Contoso.ImageGrid/ControlManifest.xml',
            'Controls/contoso_Contoso.ImageGrid/bundle.js'
        )
        Packages = @(
            @{ Path = 'src\controls\solution\ContosoRealEstateCustomControls\bin\ContosoRealEstateCustomControls.zip'; Managed = 0 },
            @{ Path = 'src\controls\solution\ContosoRealEstateCustomControls\bin\ContosoRealEstateCustomControls_managed.zip'; Managed = 1 }
        )
    },
    @{
        Name = 'Core'
        UniqueName = 'ContosoRealEstateCore'
        ProjectPath = 'src\core\solution\ContosoRealEstateCore\ContosoRealEstateCore.cdsproj'
        SolutionXmlPath = 'src\core\solution\ContosoRealEstateCore\src\Other\Solution.xml'
        RequiredEntries = @(
            'PluginAssemblies/ContosoRealEstateBusinessLogic-539003B6-E003-43C6-8BE6-AAA55B4E0337/ContosoRealEstateBusinessLogic.dll',
            'PluginAssemblies/PaymentVirtualTableProvider-47591D7B-2B3B-4C72-ABEF-A05FC384C6CF/PaymentVirtualTableProvider.dll'
        )
        Packages = @(
            @{ Path = 'src\core\solution\ContosoRealEstateCore\bin\ContosoRealEstateCore.zip'; Managed = 0 },
            @{ Path = 'src\core\solution\ContosoRealEstateCore\bin\ContosoRealEstateCore_managed.zip'; Managed = 1 }
        )
    },
    @{
        Name = 'Portal'
        UniqueName = 'ContosoRealEstatePortal'
        ProjectPath = 'src\portal\solution\ContosoRealEstatePortal\ContosoRealEstatePortal.cdsproj'
        SolutionXmlPath = 'src\portal\solution\ContosoRealEstatePortal\src\Other\Solution.xml'
        RequiredEntries = @(
            'Controls/contoso_Contoso.PortalReactUI/ControlManifest.xml',
            'Controls/contoso_Contoso.PortalReactUI/bundle.js',
            'powerpagecomponents/628cc1df-0aa3-ef11-8a6a-6045bd0313fc/filecontent/portal-ui-bundle.js'
        )
        Packages = @(
            @{ Path = 'src\portal\solution\ContosoRealEstatePortal\bin\ContosoRealEstatePortal.zip'; Managed = 0 },
            @{ Path = 'src\portal\solution\ContosoRealEstatePortal\bin\ContosoRealEstatePortal_managed.zip'; Managed = 1 }
        )
    }
)

$selectedSolutions = if ($Solution -contains 'All') { @('Controls', 'Core', 'Portal') } else { $Solution }

foreach ($solutionName in $selectedSolutions) {
    $definition = $definitions | Where-Object { $_.Name -eq $solutionName } | Select-Object -First 1
    if ($null -eq $definition) {
        throw "Unknown solution '$solutionName'."
    }

    Write-Host "`n== $solutionName ==" -ForegroundColor White
    Invoke-SolutionBuild `
        -Definition $definition `
        -RepoRoot $repoRoot `
        -SkipReferences:$SkipProjectReferences `
        -UseExistingPackages:$UseExistingPackages `
        -VerifyOnly:$VerifyOnly
}

Write-Host "`nSolution package build complete." -ForegroundColor Green