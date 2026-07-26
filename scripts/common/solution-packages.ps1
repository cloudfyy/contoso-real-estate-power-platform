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

function Invoke-DotNetBuild {
    param (
        [string]$ProjectPath
    )

    $arguments = @('build', '-c', 'Release', $ProjectPath, '/nodeReuse:false')

    Write-Host "dotnet $($arguments -join ' ')" -ForegroundColor Cyan
    & dotnet @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed for '$ProjectPath'."
    }
}

function Get-RetryDelaySeconds {
    param (
        [int]$Attempt,
        [int]$InitialDelaySeconds = 2,
        [int]$MaxDelaySeconds = 16
    )

    return [Math]::Min($MaxDelaySeconds, $InitialDelaySeconds * [Math]::Pow(2, [Math]::Max(0, $Attempt - 1)))
}

function Remove-PathIfExists {
    param (
        [string]$Path,
        [int]$MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (-not (Test-Path -Path $Path)) {
            return
        }

        try {
            Write-Host "Removing '$Path' (attempt $attempt/$MaxAttempts)" -ForegroundColor Yellow
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                Write-Host "Unable to fully remove '$Path'. Continuing. $($_.Exception.Message)" -ForegroundColor Yellow
                return
            }

            $delaySeconds = Get-RetryDelaySeconds -Attempt $attempt
            Write-Host "Unable to remove '$Path'. Retrying after $delaySeconds seconds. $($_.Exception.Message)" -ForegroundColor Yellow
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Clear-SolutionPackageTransientFolders {
    param (
        [string]$SolutionFolder
    )

    @('Metadata', 'SolutionPackager', 'SolutionPackagerLogs', 'obj') | ForEach-Object {
        Remove-PathIfExists -Path (Join-Path -Path $SolutionFolder -ChildPath $_)
    }
}

function Get-LargestFreeFileSystemRoot {
    $drive = Get-PSDrive -PSProvider FileSystem |
        Where-Object { $null -ne $_.Free -and -not [string]::IsNullOrWhiteSpace($_.Root) } |
        Sort-Object -Property Free -Descending |
        Select-Object -First 1

    if ($null -eq $drive) {
        throw 'Could not find a filesystem drive for isolated workspace builds.'
    }

    return $drive.Root
}

function Get-IsolatedWorkspaceRegistryKey {
    return 'HKCU:\Software\ContosoRealEstate\BuildReleasePackages'
}

function Get-IsolatedWorkspaceRegistryValueName {
    param (
        [string]$RepoRoot
    )

    $normalizedRepoRoot = $RepoRoot.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedRepoRoot)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }

    $hashText = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return "IsolatedWorkspace_$($hashText.Substring(0, 16))"
}

function Get-RegisteredIsolatedWorkspaceRoot {
    param (
        [string]$RepoRoot
    )

    $registryKey = Get-IsolatedWorkspaceRegistryKey
    $valueName = Get-IsolatedWorkspaceRegistryValueName -RepoRoot $RepoRoot
    $item = Get-ItemProperty -Path $registryKey -Name $valueName -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }

    $workspacePath = [string]$item.$valueName
    if ([string]::IsNullOrWhiteSpace($workspacePath)) {
        return $null
    }

    return $workspacePath
}

function Set-RegisteredIsolatedWorkspaceRoot {
    param (
        [string]$RepoRoot,
        [string]$WorkspaceRoot
    )

    $registryKey = Get-IsolatedWorkspaceRegistryKey
    $valueName = Get-IsolatedWorkspaceRegistryValueName -RepoRoot $RepoRoot
    New-Item -Path $registryKey -Force > $null
    Set-ItemProperty -Path $registryKey -Name $valueName -Value $WorkspaceRoot
}

function Remove-RegisteredIsolatedWorkspaceRoot {
    param (
        [string]$RepoRoot
    )

    $registryKey = Get-IsolatedWorkspaceRegistryKey
    $valueName = Get-IsolatedWorkspaceRegistryValueName -RepoRoot $RepoRoot
    Remove-ItemProperty -Path $registryKey -Name $valueName -ErrorAction SilentlyContinue
}

function Get-DefaultIsolatedWorkspaceRoot {
    param (
        [string]$RepoRoot
    )

    $rootDrive = Get-LargestFreeFileSystemRoot
    $repoName = Split-Path -Path $RepoRoot -Leaf
    if ([string]::IsNullOrWhiteSpace($repoName)) {
        $repoName = 'repository'
    }

    return Join-Path -Path $rootDrive -ChildPath "cre-build-$repoName"
}

function Get-IsolatedMarkerPath {
    param (
        [string]$Path
    )

    return Join-Path -Path $Path -ChildPath '.contoso-isolated-build'
}

function Assert-IsolatedOwnedPath {
    param (
        [string]$Path,
        [string]$Purpose
    )

    if (-not (Test-Path -Path $Path)) {
        return
    }

    $markerPath = Get-IsolatedMarkerPath -Path $Path
    if (-not (Test-Path -Path $markerPath)) {
        throw "$Purpose directory '$Path' already exists, but it was not created by this script. Remove it manually or choose another location."
    }
}

function Initialize-IsolatedOwnedPath {
    param (
        [string]$Path,
        [string]$Purpose
    )

    Assert-IsolatedOwnedPath -Path $Path -Purpose $Purpose
    New-Item -ItemType Directory -Path $Path -Force > $null
    Set-IsolatedOwnedPathMarker -Path $Path -Purpose $Purpose
}

function Set-IsolatedOwnedPathMarker {
    param (
        [string]$Path,
        [string]$Purpose
    )

    Set-Content -Path (Get-IsolatedMarkerPath -Path $Path) -Value $Purpose -Encoding utf8
}

function Remove-IsolatedOwnedPath {
    param (
        [string]$Path,
        [string]$Purpose
    )

    if (-not (Test-Path -Path $Path)) {
        Write-Host "$Purpose directory '$Path' was not found." -ForegroundColor Yellow
        return $false
    }

    Assert-IsolatedOwnedPath -Path $Path -Purpose $Purpose
    Write-Host "Removing $Purpose directory '$Path'" -ForegroundColor Yellow
    Remove-Item -Path $Path -Recurse -Force
    return $true
}

function Get-OrCreateIsolatedWorkspaceRoot {
    param (
        [string]$RepoRoot
    )

    $registeredPath = Get-RegisteredIsolatedWorkspaceRoot -RepoRoot $RepoRoot
    if (-not [string]::IsNullOrWhiteSpace($registeredPath)) {
        if (Test-Path -Path $registeredPath) {
            Assert-IsolatedOwnedPath -Path $registeredPath -Purpose 'isolated workspace'
            return (Get-Item -Path $registeredPath).FullName
        }

        Write-Host "Registered isolated workspace '$registeredPath' was not found. Creating a new one." -ForegroundColor Yellow
    }

    $workspaceRoot = Get-DefaultIsolatedWorkspaceRoot -RepoRoot $RepoRoot
    Initialize-IsolatedOwnedPath -Path $workspaceRoot -Purpose 'isolated workspace'
    Set-RegisteredIsolatedWorkspaceRoot -RepoRoot $RepoRoot -WorkspaceRoot $workspaceRoot
    return (Get-Item -Path $workspaceRoot).FullName
}

function Clear-RegisteredIsolatedWorkspace {
    param (
        [string]$RepoRoot
    )

    $registeredPath = Get-RegisteredIsolatedWorkspaceRoot -RepoRoot $RepoRoot
    if ([string]::IsNullOrWhiteSpace($registeredPath)) {
        Write-Host 'No registered isolated workspace was found for this repository.' -ForegroundColor Yellow
        return $false
    }

    if (Test-Path -Path $registeredPath) {
        Remove-IsolatedOwnedPath -Path $registeredPath -Purpose 'isolated workspace' > $null
    }
    else {
        Write-Host "Registered isolated workspace '$registeredPath' was not found on disk." -ForegroundColor Yellow
    }

    Remove-RegisteredIsolatedWorkspaceRoot -RepoRoot $RepoRoot
    Write-Host 'Cleared registered isolated workspace for this repository.' -ForegroundColor Green
    return $true
}

function Invoke-RobocopyMirror {
    param (
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludeDirectories = @(),
        [string[]]$ExcludeFiles = @()
    )

    New-Item -ItemType Directory -Path $Destination -Force > $null

    $arguments = @(
        $Source,
        $Destination,
        '/MIR',
        '/R:3',
        '/W:2',
        '/NFL',
        '/NDL',
        '/NP',
        '/NJH',
        '/NJS'
    )
    if ($ExcludeDirectories.Count -gt 0) {
        $arguments += @('/XD') + $ExcludeDirectories
    }
    if ($ExcludeFiles.Count -gt 0) {
        $arguments += @('/XF') + $ExcludeFiles
    }

    & robocopy @arguments
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed from '$Source' to '$Destination'. Exit code: $LASTEXITCODE."
    }
}

function Copy-RepositoryToIsolatedWorkspace {
    param (
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    Initialize-IsolatedOwnedPath -Path $DestinationRoot -Purpose 'isolated workspace'

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

    Write-Host "Copying repository to isolated workspace '$DestinationRoot'" -ForegroundColor Cyan
    Invoke-RobocopyMirror `
        -Source $SourceRoot `
        -Destination $DestinationRoot `
        -ExcludeDirectories $excludeDirectories `
        -ExcludeFiles $excludeFiles
    Set-IsolatedOwnedPathMarker -Path $DestinationRoot -Purpose 'isolated workspace'
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
        [switch]$VerifyOnly,
        [int]$MaxAttempts = 5
    )

    $projectPath = Join-Path -Path $RepoRoot -ChildPath $Definition.ProjectPath
    $solutionFolder = Split-Path -Path $projectPath -Parent
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

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if (-not $VerifyOnly) {
                Clear-SolutionPackageTransientFolders -SolutionFolder $solutionFolder
                Write-Host "Building $($Definition.Name) solution package (attempt $attempt/$MaxAttempts)" -ForegroundColor Cyan
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

            return
        }
        catch {
            if ($VerifyOnly -or $attempt -ge $MaxAttempts) {
                throw
            }

            Write-Host "Build attempt $attempt/$MaxAttempts failed for $($Definition.Name). $($_.Exception.Message)" -ForegroundColor Yellow
            Clear-SolutionPackageTransientFolders -SolutionFolder $solutionFolder

            $delaySeconds = Get-RetryDelaySeconds -Attempt $attempt
            Write-Host "Retrying $($Definition.Name) solution package build after $delaySeconds seconds." -ForegroundColor Yellow
            Start-Sleep -Seconds $delaySeconds
        }
    }
}
