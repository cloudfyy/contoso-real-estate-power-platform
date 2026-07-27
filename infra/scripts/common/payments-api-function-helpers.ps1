# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Get-RequiredValue {
    param (
        [object]$Value,
        [string]$Name
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Required environment value '$Name' was not set. Run azd provision first."
    }

    return [string]$Value
}

function Get-FunctionAppSetting {
    param (
        [string]$ResourceGroupName,
        [string]$FunctionAppName,
        [string]$Name
    )

    return az functionapp config appsettings list `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --query "[?name=='$Name'].value | [0]" `
        --output tsv
}

function Get-PaymentsApiAccessToken {
    param (
        [string]$TenantId,
        [string]$ApiAppId,
        [string]$ApiClientAppId,
        [string]$ApiClientSecret,
        [int]$RetryCount = 1
    )

    $body = @{
        client_id = $ApiClientAppId
        client_secret = $ApiClientSecret
        grant_type = 'client_credentials'
        scope = "api://$ApiAppId/.default"
    }
    $encodedBody = ($body.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f [System.Net.WebUtility]::UrlEncode($_.Key), [System.Net.WebUtility]::UrlEncode($_.Value)
    }) -join '&'

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $tokenResponse = Invoke-RestMethod `
                -Method Post `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -ContentType 'application/x-www-form-urlencoded' `
                -Body $encodedBody

            return $tokenResponse.access_token
        }
        catch {
            if ($_.ErrorDetails.Message -notlike '*invalid_client*' -or $attempt -eq $RetryCount) {
                throw
            }

            Start-Sleep -Seconds 5
        }
    }
}

function Test-PaymentsApiClientSecret {
    param (
        [string]$TenantId,
        [string]$ClientAppId,
        [string]$ApiAppId,
        [string]$ClientSecret
    )

    if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
        return $false
    }

    try {
        $token = Get-PaymentsApiAccessToken `
            -TenantId $TenantId `
            -ApiAppId $ApiAppId `
            -ApiClientAppId $ClientAppId `
            -ApiClientSecret $ClientSecret

        return -not [string]::IsNullOrWhiteSpace($token)
    }
    catch {
        Write-Host "Existing Payments API client secret is not usable. $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Test-EasyAuthClientSecret {
    param (
        [string]$TenantId,
        [string]$ApiAppId,
        [string]$ClientSecret
    )

    if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
        return $false
    }

    $body = @{
        client_id = $ApiAppId
        client_secret = $ClientSecret
        grant_type = 'client_credentials'
        scope = "api://$ApiAppId/.default"
    }

    try {
        $tokenResponse = Invoke-RestMethod `
            -Method Post `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body $body

        return -not [string]::IsNullOrWhiteSpace($tokenResponse.access_token)
    }
    catch {
        Write-Host "Existing EasyAuth client secret is not usable. $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function New-EntraClientSecret {
    param (
        [string]$ApplicationObjectId,
        [string]$DisplayName,
        [string]$TenantId
    )

    $endDateTime = (Get-Date).ToUniversalTime().AddDays(60).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $body = @{
        passwordCredential = @{
            displayName = $DisplayName
            endDateTime = $endDateTime
        }
    } | ConvertTo-Json -Depth 4 -Compress

    Write-Host "Generating Entra client secret '$DisplayName' for application object '$ApplicationObjectId'"
    $bodyFile = New-TemporaryFile
    Set-Content -Path $bodyFile -Value $body -Encoding utf8

    try {
        $credentialResult = az rest `
            --method post `
            --url "https://graph.microsoft.com/v1.0/applications/$ApplicationObjectId/addPassword" `
            --body "@$bodyFile" `
            --headers 'Content-Type=application/json' `
            --output json 2>&1

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = ($credentialResult | Out-String).Trim()
            if ($errorMessage -match 'InteractionRequired|TokenCreatedWithOutdatedPolicies|InvalidAuthenticationToken') {
                throw "Microsoft Graph requires a fresh Azure CLI login before a new client secret can be generated. No Function App settings were updated. Run 'az logout', then 'az login --tenant $TenantId', then rerun 'azd provision --environment <environment-name>'. Original error: $errorMessage"
            }

            throw "Microsoft Graph addPassword request failed. $errorMessage"
        }

        $credential = $credentialResult | ConvertFrom-Json
    }
    finally {
        Remove-Item -Path $bodyFile -Force
    }

    if ([string]::IsNullOrWhiteSpace($credential.secretText)) {
        throw "Microsoft Graph did not return a generated client secret for '$DisplayName'."
    }

    return [PSCustomObject]@{
        KeyId = $credential.keyId
        SecretText = $credential.secretText
        EndDateTime = $endDateTime
    }
}

function Remove-PreviousEntraClientSecrets {
    param (
        [string]$ApplicationId,
        [string]$DisplayName,
        [string]$CurrentKeyId
    )

    $existingCredentials = az ad app credential list --id $ApplicationId --output json | ConvertFrom-Json
    $existingCredentials |
        Where-Object { $_.displayName -eq $DisplayName -and $_.keyId -ne $CurrentKeyId } |
        ForEach-Object {
            Write-Host "Removing previous Entra client secret '$($_.keyId)' from application '$ApplicationId'"
            az ad app credential delete --id $ApplicationId --key-id $_.keyId --output none
        }
}

function ConvertFrom-Base64Url {
    param (
        [string]$Value
    )

    $base64 = $Value.Replace('-', '+').Replace('_', '/')
    switch ($base64.Length % 4) {
        2 { $base64 += '==' }
        3 { $base64 += '=' }
    }

    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($base64))
}

function Get-JwtPayload {
    param (
        [string]$Token
    )

    $parts = $Token.Split('.')
    if ($parts.Length -lt 2) {
        throw 'The Payments API access token was not a valid JWT.'
    }

    return ConvertFrom-Json (ConvertFrom-Base64Url -Value $parts[1])
}

function Get-ClaimValues {
    param (
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ })
    }

    return @([string]$Value)
}

function Get-PaymentsApiAccessTokenWithRole {
    param (
        [string]$TenantId,
        [string]$ApiAppId,
        [string]$ApiClientAppId,
        [string]$ApiClientSecret,
        [string]$RequiredRole,
        [int]$RetryCount = 36
    )

    $expectedAudience = "api://$ApiAppId"
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $token = Get-PaymentsApiAccessToken `
            -TenantId $TenantId `
            -ApiAppId $ApiAppId `
            -ApiClientAppId $ApiClientAppId `
            -ApiClientSecret $ApiClientSecret

        $payload = Get-JwtPayload -Token $token
        $audiences = Get-ClaimValues -Value $payload.aud
        $roles = Get-ClaimValues -Value $payload.roles

        if ($audiences -contains $expectedAudience -and $roles -contains $RequiredRole) {
            Write-Host "Access token contains audience '$expectedAudience' and role '$RequiredRole'." -ForegroundColor Yellow
            return $token
        }

        $audienceDisplay = if ($audiences.Count -gt 0) { $audiences -join ', ' } else { '<none>' }
        $roleDisplay = if ($roles.Count -gt 0) { $roles -join ', ' } else { '<none>' }
        Write-Host "Access token does not contain the expected claims yet (attempt $attempt/$RetryCount, aud: $audienceDisplay, roles: $roleDisplay)." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }

    throw "Could not acquire an access token containing audience '$expectedAudience' and role '$RequiredRole'. Check the app role assignment and admin consent for client app '$ApiClientAppId'."
}

function Restart-FunctionAppAndWait {
    param (
        [string]$ResourceGroupName,
        [string]$FunctionAppName,
        [string]$FunctionAppUri
    )

    Write-Host "Restarting Function App '$FunctionAppName'" -ForegroundColor Yellow
    az functionapp restart `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --output none

    $readinessProbeUri = "$FunctionAppUri/api/ping/function-ready"
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            Invoke-RestMethod -Method Get -Uri $readinessProbeUri | Out-Null
            return
        }
        catch {
            $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            Write-Host "Function App is not ready yet (attempt $attempt/60, status $statusCode)." -ForegroundColor Yellow
        }

        Start-Sleep -Seconds 5
    }

    throw "Function App '$FunctionAppName' did not become ready after restart. Last checked '$readinessProbeUri'."
}

function Wait-FunctionAppSetting {
    param (
        [string]$ResourceGroupName,
        [string]$FunctionAppName,
        [string]$Name,
        [string]$ExpectedValue,
        [switch]$RedactValue
    )

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $actualValue = az functionapp config appsettings list `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --query "[?name=='$Name'].value | [0]" `
            --output tsv

        if ($actualValue -eq $ExpectedValue) {
            $displayValue = if ($RedactValue) { '<redacted>' } else { $actualValue }
            Write-Host "Function App setting $Name=$displayValue" -ForegroundColor Yellow
            return
        }

        $displayValue = if ($RedactValue) { '<redacted>' } else { $actualValue }
        Write-Host "Waiting for Function App setting $Name to match expected value (attempt $attempt/30, current value '$displayValue')." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }

    throw "Function App setting '$Name' did not become the expected value."
}
