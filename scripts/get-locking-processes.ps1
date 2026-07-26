[CmdletBinding()]
param (
	[Parameter(Mandatory = $true, Position = 0)]
	[string]$Path,

	[int]$MaxFiles = 100
)

$ErrorActionPreference = 'Stop'

if ($MaxFiles -le 0) {
	throw '-MaxFiles must be greater than 0.'
}

if (-not (Test-Path -Path $Path)) {
	throw "Path was not found: '$Path'"
}

if (-not ('RmApi' -as [type])) {
	Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class RmApi
{
	public const int CCH_RM_MAX_APP_NAME = 255;
	public const int CCH_RM_MAX_SVC_NAME = 63;
	public const int ERROR_MORE_DATA = 234;

	[StructLayout(LayoutKind.Sequential)]
	public struct RM_UNIQUE_PROCESS
	{
		public int dwProcessId;
		public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
	}

	public enum RM_APP_TYPE
	{
		RmUnknownApp = 0,
		RmMainWindow = 1,
		RmOtherWindow = 2,
		RmService = 3,
		RmExplorer = 4,
		RmConsole = 5,
		RmCritical = 1000
	}

	[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
	public struct RM_PROCESS_INFO
	{
		public RM_UNIQUE_PROCESS Process;

		[MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
		public string strAppName;

		[MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
		public string strServiceShortName;

		public RM_APP_TYPE ApplicationType;
		public uint AppStatus;
		public uint TSSessionId;

		[MarshalAs(UnmanagedType.Bool)]
		public bool bRestartable;
	}

	[DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
	public static extern int RmStartSession(
		out uint pSessionHandle,
		int dwSessionFlags,
		StringBuilder strSessionKey);

	[DllImport("rstrtmgr.dll")]
	public static extern int RmEndSession(uint pSessionHandle);

	[DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
	public static extern int RmRegisterResources(
		uint pSessionHandle,
		uint nFiles,
		string[] rgsFilenames,
		uint nApplications,
		IntPtr rgApplications,
		uint nServices,
		string[] rgsServiceNames);

	[DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
	public static extern int RmGetList(
		uint dwSessionHandle,
		out uint pnProcInfoNeeded,
		ref uint pnProcInfo,
		[In, Out] RM_PROCESS_INFO[] rgAffectedApps,
		ref uint lpdwRebootReasons);
}
'@
}

function Get-LockingProcessesForFile {
	param (
		[Parameter(Mandatory = $true)]
		[string]$FilePath
	)

	$sessionKey = [System.Text.StringBuilder]::new(64)
	[uint32]$sessionHandle = 0

	$result = [RmApi]::RmStartSession([ref]$sessionHandle, 0, $sessionKey)
	if ($result -ne 0) {
		throw "RmStartSession failed with code $result."
	}

	try {
		$result = [RmApi]::RmRegisterResources(
			$sessionHandle,
			1,
			@($FilePath),
			0,
			[IntPtr]::Zero,
			0,
			$null
		)
		if ($result -ne 0) {
			throw "RmRegisterResources failed for '$FilePath' with code $result."
		}

		[uint32]$needed = 0
		[uint32]$count = 0
		[uint32]$rebootReasons = 0

		$result = [RmApi]::RmGetList(
			$sessionHandle,
			[ref]$needed,
			[ref]$count,
			$null,
			[ref]$rebootReasons
		)

		if ($result -eq [RmApi]::ERROR_MORE_DATA) {
			$info = [RmApi+RM_PROCESS_INFO[]]::new($needed)
			$count = $needed
			$result = [RmApi]::RmGetList(
				$sessionHandle,
				[ref]$needed,
				[ref]$count,
				$info,
				[ref]$rebootReasons
			)

			if ($result -ne 0) {
				throw "RmGetList failed for '$FilePath' with code $result."
			}

			return @(
				$info |
					Select-Object -First $count |
					ForEach-Object {
						$resolvedProcessName = $_.strAppName
						$resolvedProcessPath = ''
						try {
							$process = Get-Process -Id $_.Process.dwProcessId -ErrorAction Stop
							$resolvedProcessName = $process.ProcessName
							$resolvedProcessPath = $process.Path
						}
						catch {
						}

						[pscustomobject]@{
							File = $FilePath
							ProcessName = $resolvedProcessName
							ProcessId = $_.Process.dwProcessId
							ProcessPath = $resolvedProcessPath
						}
					}
			)
		}

		if ($result -eq 0) {
			return @()
		}

		throw "RmGetList failed for '$FilePath' with code $result."
	}
	finally {
		[void][RmApi]::RmEndSession($sessionHandle)
	}
}

$resolvedPath = (Resolve-Path -Path $Path).ProviderPath
$pathItem = Get-Item -Path $resolvedPath

$targetFiles = if ($pathItem.PSIsContainer) {
	@(
		Get-ChildItem -Path $resolvedPath -Recurse -File -ErrorAction SilentlyContinue |
			Select-Object -First $MaxFiles -ExpandProperty FullName
	)
}
else {
	@($pathItem.FullName)
}

if ($targetFiles.Count -eq 0) {
	Write-Host "No files found under '$resolvedPath'."
	return
}

if ($pathItem.PSIsContainer) {
	Write-Host "Scanning up to $MaxFiles files under '$resolvedPath'" -ForegroundColor Cyan
}

$locks = foreach ($targetFile in $targetFiles) {
	Get-LockingProcessesForFile -FilePath $targetFile
}

if (-not $locks -or $locks.Count -eq 0) {
	Write-Host 'No locking processes found.' -ForegroundColor Green
	return
}

$locks |
	Sort-Object -Property File, ProcessName, ProcessId -Unique |
	Format-Table -AutoSize
