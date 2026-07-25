# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

param (
    [string]$azureEnv,
    [bool]$skipLoginChecks
)

function AssertSolutionImported {
    param (
        [string]$SolutionUniqueName
    )

    $solutionsJson = pac solution list --json
    if ([string]::IsNullOrWhiteSpace($solutionsJson)) {
        throw "Could not read Power Platform solutions for the current environment. Check that PAC CLI is authenticated to the target environment."
    }

    $solutions = $solutionsJson | ConvertFrom-Json
    $solution = $solutions | Where-Object { $_.SolutionUniqueName -eq $SolutionUniqueName } | Select-Object -First 1
    if ($null -eq $solution) {
        throw "Solution '$SolutionUniqueName' is not imported in the current Power Platform environment. Run src\core\solution\deployment-scripts\1-deploy-to-development-environment.ps1 first and answer Y at the deployment confirmation prompt, then rerun this script."
    }
}

function SetRedirectUrl {


    # Prompt for the redirect url from the custom connector
    $redirectUrl = Read-Host "Paste the redirect url from the connector (Right click to paste in the console)"

    $appId = $envVars.ENTRA_API_CLIENT_APP_ID

    # Get the current reply urls for the client application registration
    $currentRedirectUris = az ad app show --id $appId --query "web.redirectUris" -o json | ConvertFrom-Json

    # If $currentRedirectUris is a string, add it to an array
    if ($currentRedirectUris -is [string]) {
        $currentRedirectUris = @($currentRedirectUris)
    }

    Write-Host "Existing redirect URIs: $($currentRedirectUris -join ', ')" -ForegroundColor Green

    # Check if the $redirectUrl is already in the redirect URIs
    if ($currentRedirectUris -contains $redirectUrl) {
        Write-Host "The redirect URI '$redirectUrl' is already in the client application '$appId'" -ForegroundColor Yellow
        return
    }

    # Append the new redirect URI
    $currentRedirectUris += $redirectUrl

    Write-Host "Adding the web reply urls  '$redirectUrl' to the client application '$appId'" -ForegroundColor Green

    az ad app update --id $appId --web-redirect-uris $currentRedirectUris

    Write-Host "Complete" -ForegroundColor Green
}

# -------------------------------------------------------------------------
function FixCustomConnector {
    param (
        [string]$connectorName,
        [string]$environmentId,
        [string]$apiAppId
    )
    Write-Host
    Write-Host "Fixing up Custom Connector '$connectorName'" -ForegroundColor Green
    $customConnectorUrl = "https://make.powerautomate.com/environments/$environmentId/connections/custom"

    # $customConnectorUrl = "https://make.powerautomate.com/environments/$environmentId/connections/available/custom/$connectorName/edit/security"
    Write-Host "1. Open the [$connectorName] custom connector "
    Write-Host $customConnectorUrl -ForegroundColor Blue
    Write-Host ""
    Write-Host "2. Edit the connector security settings and paste the Payments API client secret as the OAuth client secret." -ForegroundColor Yellow
    Write-Host "   To display the secret, run this from the repository root:" -ForegroundColor Yellow
    Write-Host "   .\infra\scripts\show-payments-api-client-secret.ps1 -azureEnv $azureEnv" -ForegroundColor Blue
    Write-Host ""
    Write-host "3. Copy the 'Redirect URL'"
    SetRedirectUrl
    Write-Host ""
}

Write-Host "This script will setup your Payment API client application registration in Entra ID with the custom connector reply url" -ForegroundColor White
# -------------------------------------------------------------------------
# Import the environment variables
# -------------------------------------------------------------------------
. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv

# Check the user is logged into AZ CLI and PAC
if (-not $skipLoginChecks) {
    CheckAZCLI
}

$environmentDetails = pac env who --json | ConvertFrom-Json
$environmentId = $environmentDetails.EnvironmentId

AssertSolutionImported -SolutionUniqueName 'ContosoRealEstateCore'

FixCustomConnector -connectorName "Contoso Payments API" -environmentId $environmentId -apiAppId $envVars.ENTRA_API_APP_ID
FixCustomConnector -connectorName "Contoso Stripe API" -environmentId $environmentId -apiAppId $envVars.ENTRA_API_APP_ID
