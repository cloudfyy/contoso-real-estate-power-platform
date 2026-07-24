# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Use Powershell to create a self signed certificate for testing purposes.
Import-Module PKI

# Create a secure string for the password
$password = ConvertTo-SecureString -String "ContosoRealEsate" -Force -AsPlainText

# Create a self-signed certificate
$certificate = New-SelfSignedCertificate -Subject "CN=contoso.com, O=Contoso, C=US" -DnsName "contoso.com" -Type CodeSigning -KeyUsage DigitalSignature -CertStoreLocation Cert:\CurrentUser\My -FriendlyName "Contoso Real Estate Self Signed Cert" -NotAfter (Get-Date).AddYears(5)

# Export the certificate to PFX
Export-PfxCertificate -Cert $certificate -FilePath "$PSScriptRoot/certificate.pfx" -Password $password
$certificate.Thumbprint | Out-File -FilePath "$PSScriptRoot/thumbprint.txt"
