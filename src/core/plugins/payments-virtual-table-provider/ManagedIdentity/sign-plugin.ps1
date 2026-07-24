# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Locate the SignTool.exe without using Get-Command
$signToolPath = (Get-ChildItem -Path "C:\Program Files (x86)\Windows Kits" -Recurse -Filter "signtool.exe" -ErrorAction SilentlyContinue -Force | Where-Object { $_.FullName -like "*x86\signtool.exe" })

if ($signToolPath) {
    $signToolPath = $signToolPath[0].FullName
}
else {
    Write-Error "SignTool.exe not found"
    exit 1
}

$certPath = Join-Path -Path $PSScriptRoot -ChildPath "certificate.pfx"

if (-not (Test-Path -Path $certPath)) {
    Write-Error "Certificate file not found at $certPath. Run generate-self-signed-cert.ps1 to create a development signing certificate."
    exit 1
}

$certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath, "ContosoRealEsate")
if ($certificate.NotAfter -lt (Get-Date)) {
    Write-Error "Certificate at $certPath expired on $($certificate.NotAfter). Run generate-self-signed-cert.ps1 to create a new development signing certificate."
    exit 1
}

$pluginPath = Join-Path -Path $PSScriptRoot -ChildPath  "../PaymentVirtualTableProvider/bin/PaymentVirtualTableProvider.dll" 

if (-not (Test-Path -Path $pluginPath)) {
    Write-Error "Plugin assembly not found at $pluginPath"
    exit 1
}

Write-Host "Signing the plugin at $pluginPath with the certificate at $certPath" -ForegroundColor Green
& $signToolPath sign /fd SHA256 /f $certPath /p "ContosoRealEsate" "$pluginPath"
$signToolExitCode = $LASTEXITCODE
if ($signToolExitCode -ne 0) {
    Write-Error "SignTool failed with exit code $signToolExitCode."
    exit $signToolExitCode
}
