# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
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

function Get-GitHubRepositoryName {
    param (
        [string]$RemoteName
    )

    $remoteUrl = git remote get-url $RemoteName 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
        throw "Unable to read git remote '$RemoteName'."
    }

    if ($remoteUrl -match 'github\.com[:/]([^/]+)/(.+?)(\.git)?$') {
        $owner = $matches[1]
        $repositoryName = $matches[2] -replace '\.git$', ''
        return "$owner/$repositoryName"
    }

    throw "Unable to determine GitHub repository from remote '$RemoteName' URL '$remoteUrl'."
}

function Get-SolutionManifest {
    param (
        [string]$SolutionXmlPath
    )

    [xml]$solutionXml = Get-Content -Path $SolutionXmlPath -Raw
    return [pscustomobject]@{
        Document = $solutionXml
        Manifest = $solutionXml.ImportExportXml.SolutionManifest
    }
}

function Get-SolutionVersion {
    param (
        [string]$SolutionXmlPath
    )

    $manifestInfo = Get-SolutionManifest -SolutionXmlPath $SolutionXmlPath
    return [string]$manifestInfo.Manifest.Version
}

function Get-NextSolutionVersion {
    param (
        [string]$CurrentVersion
    )

    $parts = @($CurrentVersion.Split('.') | ForEach-Object { [int]$_ })
    if ($parts.Count -ne 4) {
        throw "Solution version '$CurrentVersion' must have four numeric parts."
    }

    $parts[2]++
    $parts[3] = 0
    return ($parts -join '.')
}

function Get-ReleaseVersion {
    param (
        [string]$SolutionVersion
    )

    $parts = @($SolutionVersion.Split('.'))
    if ($parts.Count -ne 4) {
        throw "Solution version '$SolutionVersion' must have four parts."
    }

    return ($parts[0..2] -join '.')
}

function Set-SolutionVersion {
    param (
        [string]$SolutionXmlPath,
        [string]$Version
    )

    [xml]$solutionXml = Get-Content -Path $SolutionXmlPath -Raw
    $solutionXml.ImportExportXml.SolutionManifest.Version = $Version
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $settings.NewLineChars = "`r`n"

    $writer = [System.Xml.XmlWriter]::Create($SolutionXmlPath, $settings)
    try {
        $solutionXml.Save($writer)
    }
    finally {
        $writer.Dispose()
    }
}

function Get-SolutionPackageDefinitions {
    return @(
        @{
            Name = 'Controls'
            UniqueName = 'ContosoRealEstateCustomControls'
            ReleaseName = 'ContosoRealEstateCustomControls'
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
            ReleaseName = 'ContosoRealEstateCore'
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
            ReleaseName = 'ContosoRealEstatePortal'
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
}

function Resolve-SolutionPackageDefinitions {
    param (
        [string[]]$Solution = @('All')
    )

    $definitions = Get-SolutionPackageDefinitions
    $selectedSolutions = if ($Solution -contains 'All') { @('Controls', 'Core', 'Portal') } else { $Solution }

    foreach ($solutionName in $selectedSolutions) {
        $definition = $definitions | Where-Object { $_.Name -eq $solutionName } | Select-Object -First 1
        if ($null -eq $definition) {
            throw "Unknown solution '$solutionName'."
        }

        $definition
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
