# Solution Build File Lock Troubleshooting

This guide covers transient file lock errors that can happen while building Dataverse solution packages with `Microsoft.PowerApps.MSBuild.Solution`.

## Symptom

A solution build fails while Solution Packager is cleaning or recreating its metadata folder:

```text
<user-profile>\.nuget\packages\microsoft.powerapps.msbuild.solution\<version>\build\Microsoft.PowerApps.MSBuild.Solution.targets(...): error MSB3231: Unable to remove directory "obj\Release\Metadata". The process cannot access the file '\\?\<repo_root>\src\...\obj\Release\Metadata\...' because it is being used by another process.
```

The locked path might also be under one of these folders:

```text
<repo_root>\src\...\Metadata
<repo_root>\src\...\SolutionPackager
<repo_root>\src\...\SolutionPackagerLogs
<repo_root>\src\...\obj\Release\Metadata
```

## Common Causes

- A previous `dotnet build`, `MSBuild`, `SolutionPackager`, `node`, or `cmd` process has not fully exited.
- Another terminal is still building the same solution.
- VS Code, File Explorer, search indexing, or antivirus is scanning the generated metadata files.
- A build was stopped while Solution Packager was writing files.
- A second build was started immediately after a previous build completed, before Windows released file handles.

## Find Build-Related Processes

Run this from the repository root. It does not print secrets.

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.Name -match 'dotnet|MSBuild|SolutionPackager|node|npm|cmd' -and
    $_.CommandLine -match 'contoso-real-estate-power-platform|ContosoRealEstate|SolutionPackager'
  } |
  Select-Object ProcessId, Name, CommandLine |
  Format-List
```

For a specific solution, narrow the command line match:

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.CommandLine -match 'src\\controls\\solution\\ContosoRealEstateCustomControls'
  } |
  Select-Object ProcessId, Name, CommandLine |
  Format-List
```

If the listed process is a stale build process, stop it:

```powershell
Get-CimInstance Win32_Process |
  Where-Object {
    $_.CommandLine -match 'src\\controls\\solution\\ContosoRealEstateCustomControls'
  } |
  ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
  }
```

Only stop processes that are clearly related to the build you are trying to unblock.

## Manual Cleanup

If no related process is running, wait a few seconds and remove the transient packaging folders:

```powershell
Set-Location <repo_root>

Remove-Item -Recurse -Force `
  .\src\controls\solution\ContosoRealEstateCustomControls\obj, `
  .\src\controls\solution\ContosoRealEstateCustomControls\Metadata, `
  .\src\controls\solution\ContosoRealEstateCustomControls\SolutionPackager, `
  .\src\controls\solution\ContosoRealEstateCustomControls\SolutionPackagerLogs `
  -ErrorAction SilentlyContinue
```

For Core:

```powershell
Remove-Item -Recurse -Force `
  .\src\core\solution\ContosoRealEstateCore\obj, `
  .\src\core\solution\ContosoRealEstateCore\Metadata, `
  .\src\core\solution\ContosoRealEstateCore\SolutionPackager, `
  .\src\core\solution\ContosoRealEstateCore\SolutionPackagerLogs `
  -ErrorAction SilentlyContinue
```

For Portal:

```powershell
Remove-Item -Recurse -Force `
  .\src\portal\solution\ContosoRealEstatePortal\obj, `
  .\src\portal\solution\ContosoRealEstatePortal\Metadata, `
  .\src\portal\solution\ContosoRealEstatePortal\SolutionPackager, `
  .\src\portal\solution\ContosoRealEstatePortal\SolutionPackagerLogs `
  -ErrorAction SilentlyContinue
```

## Recommended Build Command

Prefer the repository build helper instead of running `dotnet build` directly:

```powershell
.\scripts\build-release-packages.ps1 -Solution Controls -Clean
```

The helper cleans transient packaging folders, tolerates locked log files, rebuilds the package, and verifies the generated zip contents.

To rebuild all packages from scratch:

```powershell
.\scripts\build-release-packages.ps1 -Clean
```

To also reinstall npm dependencies:

```powershell
.\scripts\build-release-packages.ps1 -Clean -CleanNodeModules
```

## Notes

- `SolutionPackagerLogs` files can remain locked briefly after a failed build. They are diagnostic files and usually do not need to block a retry.
- If the same directory stays locked for a long time and no build process is visible, check whether File Explorer, VS Code search, antivirus, or indexing is scanning the folder.
- Avoid starting several solution builds against the same solution folder at the same time.
