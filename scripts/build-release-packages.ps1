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
        CleanPaths = @(
            'src\controls\solution\ContosoRealEstateCustomControls\bin',
            'src\controls\solution\ContosoRealEstateCustomControls\obj',
            'src\controls\image-grid-pcf\bin',
            'src\controls\image-grid-pcf\obj',
            'src\controls\image-grid-pcf\out'
        )
        NodeModulePaths = @(
            'src\controls\image-grid-pcf\node_modules'
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
        CleanPaths = @(
            'src\core\solution\ContosoRealEstateCore\bin',
            'src\core\solution\ContosoRealEstateCore\obj',
            'src\core\solution\ContosoRealEstateCore\Metadata',
            'src\core\solution\ContosoRealEstateCore\SolutionPackager',
            'src\core\solution\ContosoRealEstateCore\SolutionPackagerLogs',
            'src\core\plugins\business-logic\ContosoRealEstateBusinessLogic\bin',
            'src\core\plugins\business-logic\ContosoRealEstateBusinessLogic\obj',
            'src\core\plugins\payments-virtual-table-provider\PaymentVirtualTableProvider\bin',
            'src\core\plugins\payments-virtual-table-provider\PaymentVirtualTableProvider\obj',
            'src\core\mda-client-hooks\dist',
            'src\core\mda-client-hooks\node_modules\.package-lock.stamp',
            'src\core\mda-client-hooks\node_modules\.webpack-build.Debug.stamp',
            'src\core\mda-client-hooks\node_modules\.webpack-build.Release.stamp'
        )
        NodeModulePaths = @(
            'src\core\mda-client-hooks\node_modules'
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
        CleanPaths = @(
            'src\portal\solution\ContosoRealEstatePortal\bin',
            'src\portal\solution\ContosoRealEstatePortal\obj',
            'src\portal\solution\ContosoRealEstatePortal\Metadata',
            'src\portal\solution\ContosoRealEstatePortal\SolutionPackager',
            'src\portal\solution\ContosoRealEstatePortal\SolutionPackagerLogs',
            'src\portal\PortalReactUI\bin',
            'src\portal\PortalReactUI\obj',
            'src\portal\PortalReactUI\out',
            'src\portal\portal-react-ui\dist',
            'src\portal\portal-react-ui\node_modules\.package-lock.stamp',
            'src\portal\portal-react-ui\node_modules\.webpack-build.Debug.stamp',
            'src\portal\portal-react-ui\node_modules\.webpack-build.Release.stamp'
        )
        NodeModulePaths = @(
            'src\portal\PortalReactUI\node_modules',
            'src\portal\portal-react-ui\node_modules'
        )
    }
)

$selectedSolutions = if ($Solution -contains 'All') { @('Controls', 'Core', 'Portal') } else { $Solution }
$solutionTimings = @()
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($solutionName in $selectedSolutions) {
    $definition = $definitions | Where-Object { $_.Name -eq $solutionName } | Select-Object -First 1
    if ($null -eq $definition) {
        throw "Unknown solution '$solutionName'."
    }

    Write-Host "`n== $solutionName ==" -ForegroundColor White
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
            Solution = $solutionName
            Seconds = [math]::Round($solutionStopwatch.Elapsed.TotalSeconds, 2)
        }
    }
}

$totalStopwatch.Stop()

Write-Host "`nBuild timing summary" -ForegroundColor White
$solutionTimings | Format-Table -AutoSize
Write-Host ("Total: {0:n2} seconds" -f $totalStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host "`nSolution package build complete." -ForegroundColor Green