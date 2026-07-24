# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# This script assigns all the app roles of the payments api to the current user for testing
# -----------------------------------------------------------------------
param (
    [string]$azureEnv
)

$ErrorActionPreference = 'Stop'

function Assert-AzCliSucceeded {
    param (
        [object]$Output,
        [string]$Operation
    )

    if ($LASTEXITCODE -eq 0) {
        return
    }

    $message = ($Output | Out-String).Trim()
    if ($message -like '*TokenCreatedWithOutdatedPolicies*' -or $message -like '*InteractionRequired*' -or $message -like '*InvalidAuthenticationToken*') {
        throw "$Operation failed because Azure CLI needs interactive authentication. Run 'az logout', then 'az login', then rerun this script. $message"
    }

    throw "$Operation failed. $message"
}

function AssignRolesToPrincipal {
    param (
        [string]$roleNames,
        [string]$principalId,
        [object]$appId
    )

    # Convert the comma-separated list to an array
    $roleNamesArray = $roleNames -split ',' | ForEach-Object { $_.Trim() }

    
    $appRolesJson = az ad app show --id $appId --query "appRoles" --output json 2>&1
    Assert-AzCliSucceeded -Output $appRolesJson -Operation "Reading Payments API app roles"
    $appRoles = $appRolesJson | ConvertFrom-Json

    # Get the service principal id
    $servicePrincipalId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" --output tsv 2>&1
    Assert-AzCliSucceeded -Output $servicePrincipalId -Operation "Reading Payments API service principal"
    if ([string]::IsNullOrWhiteSpace($servicePrincipalId)) {
        throw "Could not find the service principal for Payments API app '$appId'. Run azd provision, then rerun this script."
    }

    $existingAssignments = az rest `
        --method GET `
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$servicePrincipalId/appRoleAssignedTo?`$top=999" `
        --query "value[?principalId=='$principalId'].appRoleId" `
        --output tsv 2>&1
    Assert-AzCliSucceeded -Output $existingAssignments -Operation "Reading existing Payments API app role assignments"

    $matchedRoleNames = @()

    # Loop through each object and get the id if the value is in the list
    foreach ($item in $appRoles) {
        if ($roleNamesArray -contains $item.value) {
            $matchedRoleNames += $item.value
            if ($existingAssignments -contains $item.id) {
                Write-Host "Role $($item.value)[$($item.id)] is already assigned to principal [$principalId]" -ForegroundColor Yellow
                continue
            }

            Write-Host "Assigning role $($item.value)[$($item.id)] to principal [$principalId]" -ForegroundColor Green
            # See https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-approleassignedto?view=graph-rest-1.0&tabs=http
            $body = @{
                principalId = $principalId
                resourceId = $servicePrincipalId
                appRoleId = $item.id
            } | ConvertTo-Json -Compress

            $bodyFile = New-TemporaryFile
            Set-Content -Path $bodyFile -Value $body -Encoding utf8

            try {
                $assignmentResult = az rest `
                    --method POST `
                    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$servicePrincipalId/appRoleAssignedTo" `
                    --headers "Content-Type=application/json" `
                    --body "@$bodyFile" `
                    --output none 2>&1
                Assert-AzCliSucceeded -Output $assignmentResult -Operation "Assigning Payments API app role '$($item.value)'"
            }
            finally {
                Remove-Item -Path $bodyFile -Force
            }
        }
    }

    $missingRoleNames = $roleNamesArray | Where-Object { $matchedRoleNames -notcontains $_ }
    if ($missingRoleNames.Count -gt 0) {
        throw "The Payments API app registration does not define these app roles: $($missingRoleNames -join ', '). Run azd provision to apply the latest app role definitions, then rerun this script."
    }
}
# -----------------------------------------------------------------------
# Import the environment variables
. "$PSScriptRoot\function-get-environment-variables.ps1"
$envVars = GetEnvironmentVariables -azureEnv $azureEnv

# -----------------------------------------------------------------------
Write-Host "This script and assigns all the app roles of the payments api to the current user for testing" -ForegroundColor White

$appId = $envVars.ENTRA_API_APP_ID

# Assign the roles to the current user for testing
Write-Host "Granting access to the Payment API for the current user" -ForegroundColor Green
$currentUserPrincipalId = az ad signed-in-user show --query id -o tsv 2>&1
Assert-AzCliSucceeded -Output $currentUserPrincipalId -Operation "Reading current Azure CLI user"
AssignRolesToPrincipal -roleNames "CanAddPayments,CanQueryPayments,CanCreateStripeSessions,CanInitializePaymentsDatabase,CanConfigureStripe,CanValidatePaymentsConfiguration,CanReadPaymentsApiClientSecret,CanWritePaymentsApiClientSecret" -principalId $currentUserPrincipalId -appId $appId

# The Client for Contoso Real Estate Payments API needs admin consent if it's used as a service principal to access the API
Write-Host "Granting access to the Payment API for the SPN used in connections" -ForegroundColor Green
$clientServicePrincipalId = az ad sp list --filter "appId eq '$($envVars.ENTRA_API_CLIENT_APP_ID)'" --query "[0].id" --output tsv 2>&1
Assert-AzCliSucceeded -Output $clientServicePrincipalId -Operation "Reading Payments API client service principal"
if ([string]::IsNullOrWhiteSpace($clientServicePrincipalId)) {
    throw "Could not find the service principal for Payments API client app '$($envVars.ENTRA_API_CLIENT_APP_ID)'. Run azd provision, then rerun this script."
}
AssignRolesToPrincipal -roleNames "CanAddPayments,CanQueryPayments,CanCreateStripeSessions,CanInitializePaymentsDatabase,CanConfigureStripe,CanValidatePaymentsConfiguration,CanReadPaymentsApiClientSecret,CanWritePaymentsApiClientSecret" -principalId $clientServicePrincipalId -appId $appId
$adminConsentResult = az ad app permission admin-consent --id $envVars.ENTRA_API_CLIENT_APP_ID 2>&1
Assert-AzCliSucceeded -Output $adminConsentResult -Operation "Granting admin consent to the Payments API client app"

Write-Host "Complete" -ForegroundColor Green

