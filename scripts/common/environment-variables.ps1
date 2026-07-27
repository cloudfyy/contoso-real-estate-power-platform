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

function GetRepositoryEnvironmentVariables {
    param (
        [string]$azureEnv,
        [string]$scriptDirectory = $PSScriptRoot,
        [bool]$outputVariables = $false
    )

    $envFile = Join-Path -Path $scriptDirectory -ChildPath '.env'
    if (Test-Path -Path $envFile) {
        if ($azureEnv -eq "") {
            Write-Host "Reading from '.env' at '${envFile}'. Remove this to use the .env file in the .azure folder"
        }
        $envFolder = $envFile
    }
    else {
        $targetFolderName = ".azure"
        $currentDirectory = $scriptDirectory

        while ($currentDirectory -ne [System.IO.Directory]::GetDirectoryRoot($currentDirectory)) {
            if (Test-Path -Path (Join-Path -Path $currentDirectory -ChildPath $targetFolderName)) {
                Write-Host "Found $targetFolderName in $currentDirectory" -ForegroundColor Green
                break
            }

            $currentDirectory = Get-Item -Path (Join-Path -Path $currentDirectory -ChildPath "..")
        }

        if ($currentDirectory -eq [System.IO.Directory]::GetDirectoryRoot($currentDirectory)) {
            Write-Host "$targetFolderName not found in any parent directories." -ForegroundColor Red
            exit
        }

        $azureFolderPath = Join-Path -Path $currentDirectory -ChildPath ".azure"
        if (-not (Test-Path -Path $azureFolderPath)) {
            Write-Host "The .azure folder does not exist. Run azd up first" -ForegroundColor Red
            exit
        }

        $folders = Get-ChildItem -Path $azureFolderPath -Directory
        if ($azureEnv -eq "") {
            $defaultFolderName = GetDefaultAzureEnvironmentName -azureFolderPath $azureFolderPath -folders $folders
            $folders | ForEach-Object {
                $defaultMarker = if ($_.Name -eq $defaultFolderName) { ' (default)' } else { '' }
                Write-Host "[$($_.Name)]$defaultMarker"
            }

            $selectedFolderName = Read-Host "Enter the azure environment configuration [$defaultFolderName]"
            if ([string]::IsNullOrWhiteSpace($selectedFolderName)) {
                $selectedFolderName = $defaultFolderName
            }

            $selectedFolderName = $selectedFolderName -replace "\[|\]", ""
        }
        else {
            $selectedFolderName = $azureEnv
        }

        $selectedFolder = $folders | Where-Object { $_.Name -eq $selectedFolderName }
        if ($null -eq $selectedFolder) {
            Write-Host "Invalid .azure environment '$selectedFolderName'" -ForegroundColor Red
            exit
        }

        $environment = $selectedFolder.Name

        Write-Host "Reading from '$environment/.env'"
        $envFolder = Join-Path -Path $azureFolderPath -ChildPath "$environment/.env"

        if (-not (Test-Path -Path $envFolder)) {
            Write-Host "The file '$environment/.env' does not exist" -ForegroundColor Red
            exit
        }
    }

    $envFile = Get-Content -Path $envFolder
    $envVars = New-Object PSObject
    $envFile | ForEach-Object {
        if ($_ -match '^(.*)="(.*)"$') {
            $name = $matches[1].ToUpper()
            $value = $matches[2]
            $envVars | Add-Member -MemberType NoteProperty -Name $name -Value $value
            if ($outputVariables) {
                Write-Host " $name = '$value'" -ForegroundColor Gray
            }
        }
    }

    return $envVars
}

function GetDefaultAzureEnvironmentName {
    param (
        [string]$azureFolderPath,
        [array]$folders
    )

    $configFile = Join-Path -Path $azureFolderPath -ChildPath 'config.json'
    if (Test-Path -Path $configFile) {
        try {
            $config = Get-Content -Path $configFile -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($config.defaultEnvironment)) {
                $configuredDefault = $folders | Where-Object { $_.Name -eq $config.defaultEnvironment } | Select-Object -First 1
                if ($null -ne $configuredDefault) {
                    return $configuredDefault.Name
                }
            }
        }
        catch {
            Write-Host "Unable to read azd default environment from '$configFile'. Falling back to the first environment folder." -ForegroundColor Yellow
        }
    }

    $firstFolder = $folders | Select-Object -First 1
    return $firstFolder.Name
}

function ConfirmPrompt {
    param (
        [string]$message
    )

    while ($true) {
        Write-Host @"
$message (Y/N)
"@ -ForegroundColor Yellow

        $confirm = Read-Host
        switch ($confirm.Trim().ToUpperInvariant()) {
            'Y' { return $true }
            'N' { return $false }
            default { Write-Host "Please enter Y or N." -ForegroundColor Yellow }
        }
    }
}

function AssertCommandExists {
    param (
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found. Install it, then rerun this script."
    }
}

function AssertCommandSucceeded {
    param (
        [string]$CommandDescription,
        [object]$CommandOutput
    )

    if ($LASTEXITCODE -ne 0) {
        $output = ($CommandOutput | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($output)) {
            throw "$CommandDescription failed with exit code $LASTEXITCODE. $output"
        }

        throw "$CommandDescription failed with exit code $LASTEXITCODE."
    }
}

function InvokeExternalCommand {
    param (
        [string]$CommandDescription,
        [scriptblock]$ScriptBlock
    )

    & $ScriptBlock
    AssertCommandSucceeded -CommandDescription $CommandDescription
}

function GetRequiredValue {
    param (
        [string]$Value,
        [string]$Name
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $enteredValue = Read-Host -Prompt $Name
    if ([string]::IsNullOrWhiteSpace($enteredValue)) {
        throw "A value is required for '$Name'."
    }

    return $enteredValue
}

function Get-PowerPlatformEnvironmentUrl {
    if (-not (Get-Command 'pac' -ErrorAction SilentlyContinue)) {
        return ''
    }

    $environmentDetailsJson = pac env who --json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($environmentDetailsJson -join ''))) {
        return ''
    }

    $environmentDetails = $environmentDetailsJson | ConvertFrom-Json
    return ([string]$environmentDetails.OrgUrl).TrimEnd('/')
}

function Select-PowerPlatformEnvironmentUrl {
    param (
        [string]$Purpose = 'Power Platform environment',
        [string[]]$ExcludedEnvironmentUrls = @()
    )

    AssertCommandExists -Name 'pac'

    if ($null -eq $script:PowerPlatformEnvironmentsCache) {
        Write-Host 'Loading Power Platform environments...' -ForegroundColor Yellow
        $environmentListJson = pac env list --json 2>&1
        AssertCommandSucceeded -CommandDescription 'List Power Platform environments' -CommandOutput $environmentListJson
        $script:PowerPlatformEnvironmentsCache = @($environmentListJson | ConvertFrom-Json)
    }

    $environments = @($script:PowerPlatformEnvironmentsCache)
    if ($environments.Count -eq 0) {
        throw 'No Power Platform environments were returned for the current PAC user.'
    }

    $excludedUrls = @($ExcludedEnvironmentUrls | ForEach-Object { ([string]$_).TrimEnd('/') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    Write-Host "Select the ${Purpose}:" -ForegroundColor Yellow
    for ($index = 0; $index -lt $environments.Count; $index++) {
        $environment = $environments[$index]
        $number = $index + 1
        $friendlyName = [string]$environment.FriendlyName
        $environmentUrl = ([string]$environment.EnvironmentUrl).TrimEnd('/')
        $environmentId = [string]$environment.EnvironmentIdentifier.Id
        $selectedMarker = if ($excludedUrls -contains $environmentUrl) { ' [already selected]' } else { '' }
        Write-Host "[$number] $friendlyName - $environmentUrl ($environmentId)$selectedMarker" -ForegroundColor Yellow
    }

    while ($true) {
        $selection = Read-Host "Enter a number for the $Purpose"
        $selectionNumber = 0
        if ([int]::TryParse($selection, [ref]$selectionNumber) -and $selectionNumber -ge 1 -and $selectionNumber -le $environments.Count) {
            $selectedEnvironmentUrl = ([string]$environments[$selectionNumber - 1].EnvironmentUrl).TrimEnd('/')
            if ($excludedUrls -contains $selectedEnvironmentUrl) {
                Write-Host "Environment '$selectedEnvironmentUrl' was already selected. Choose a different environment." -ForegroundColor Yellow
                continue
            }

            return $selectedEnvironmentUrl
        }

        Write-Host "Invalid selection '$selection'. Enter a number from 1 to $($environments.Count)." -ForegroundColor Yellow
    }
}

function Select-PowerPagesPortalUrl {
    param (
        [string]$EnvironmentUrl,
        [string]$Purpose = 'Power Pages site'
    )

    AssertCommandExists -Name 'pac'

    if ([string]::IsNullOrWhiteSpace($EnvironmentUrl)) {
        throw 'A Dataverse environment URL is required to list Power Pages websites.'
    }

    $pagesListOutput = pac pages list --environment $EnvironmentUrl --verbose 2>&1
    AssertCommandSucceeded -CommandDescription "List Power Pages websites for '$EnvironmentUrl'" -CommandOutput $pagesListOutput

    $websites = @(
        foreach ($line in $pagesListOutput) {
            $trimmedLine = ([string]$line).Trim()
            if ($trimmedLine -notmatch '^\[\d+\]\s+') {
                continue
            }

            $columns = @($trimmedLine -split '\s{2,}')
            if ($columns.Count -lt 5) {
                continue
            }

            [pscustomobject]@{
                Number = [int]($columns[0].Trim('[', ']'))
                WebsiteId = [string]$columns[1]
                PortalId = [string]$columns[2]
                FriendlyName = [string]$columns[3]
                PortalUrl = ([string]$columns[4]).TrimEnd('/')
            }
        }
    )

    if ($websites.Count -eq 0) {
        throw "No Power Pages websites were returned for '$EnvironmentUrl'. Pass -PortalUrl explicitly if the site has not been created yet or is not visible to the current PAC user."
    }

    if ($websites.Count -eq 1) {
        $website = $websites[0]
        Write-Host "Using Power Pages website '$($website.FriendlyName)' - $($website.PortalUrl)" -ForegroundColor Green
        return $website.PortalUrl
    }

    Write-Host "Select the ${Purpose}:" -ForegroundColor Yellow
    for ($index = 0; $index -lt $websites.Count; $index++) {
        $website = $websites[$index]
        $number = $index + 1
        Write-Host "[$number] $($website.FriendlyName) - $($website.PortalUrl) ($($website.WebsiteId))" -ForegroundColor Yellow
    }

    while ($true) {
        $selection = Read-Host "Enter a number for the $Purpose"
        $selectionNumber = 0
        if ([int]::TryParse($selection, [ref]$selectionNumber) -and $selectionNumber -ge 1 -and $selectionNumber -le $websites.Count) {
            return $websites[$selectionNumber - 1].PortalUrl
        }

        Write-Host "Invalid selection '$selection'. Enter a number from 1 to $($websites.Count)." -ForegroundColor Yellow
    }
}

function Add-PowerPlatformApplicationUser {
    param (
        [string]$EnvironmentUrl,
        [string]$ApplicationId,
        [string]$Role = 'System Customizer'
    )

    InvokeExternalCommand -CommandDescription "Assign Power Platform application user '$ApplicationId' to '$EnvironmentUrl'" -ScriptBlock {
        pac admin assign-user --environment $EnvironmentUrl --application-user --user $ApplicationId --role $Role
    }
}

function Add-GitHubEnvironmentFederatedCredential {
    param (
        [string]$ApplicationId,
        [string]$Repository,
        [string]$EnvironmentName,
        [string]$CredentialName
    )

    if ([string]::IsNullOrWhiteSpace($CredentialName)) {
        $CredentialName = "github-$($EnvironmentName -replace '[^A-Za-z0-9-]', '-')"
    }

    $credentialSubjects = @(
        [pscustomobject]@{
            Name = $CredentialName
            Subject = "repo:${Repository}:environment:${EnvironmentName}"
        }
    )

    $repositoryJson = gh api "repos/$Repository" 2>&1
    AssertCommandSucceeded -CommandDescription "Get GitHub repository metadata for '$Repository'" -CommandOutput $repositoryJson
    $repositoryInfo = $repositoryJson | ConvertFrom-Json
    $owner = [string]$repositoryInfo.owner.login
    $ownerId = [string]$repositoryInfo.owner.id
    $repoName = [string]$repositoryInfo.name
    $repoId = [string]$repositoryInfo.id

    if (-not [string]::IsNullOrWhiteSpace($ownerId) -and -not [string]::IsNullOrWhiteSpace($repoId)) {
        $credentialSubjects += [pscustomobject]@{
            Name = "$CredentialName-id"
            Subject = "repo:${owner}@${ownerId}/${repoName}@${repoId}:environment:${EnvironmentName}"
        }
    }

    $federatedCredentialsJson = az ad app federated-credential list --id $ApplicationId --output json 2>&1
    AssertCommandSucceeded -CommandDescription "List federated credentials for '$ApplicationId'" -CommandOutput $federatedCredentialsJson

    $federatedCredentials = @($federatedCredentialsJson | ConvertFrom-Json)
    foreach ($credentialSubject in $credentialSubjects) {
        $credentialWithSubject = $federatedCredentials | Where-Object { $_.subject -eq $credentialSubject.Subject } | Select-Object -First 1
        if ($null -ne $credentialWithSubject) {
            Write-Host "Federated credential already exists for subject '$($credentialSubject.Subject)'." -ForegroundColor Green
            continue
        }

        $credentialWithName = $federatedCredentials | Where-Object { $_.name -eq $credentialSubject.Name } | Select-Object -First 1
        if ($null -ne $credentialWithName) {
            throw "Federated credential '$($credentialSubject.Name)' already exists on application '$ApplicationId' but its subject is '$($credentialWithName.subject)', expected '$($credentialSubject.Subject)'. Update or remove that credential in Entra ID, then rerun this script."
        }

        $federatedCredential = [ordered]@{
            name = $credentialSubject.Name
            issuer = 'https://token.actions.githubusercontent.com'
            subject = $credentialSubject.Subject
            description = "GitHub access for the environment $EnvironmentName and repo $Repository"
            audiences = @('api://AzureADTokenExchange')
        }
        $federatedCredentialJson = $federatedCredential | ConvertTo-Json -Depth 5 -Compress
        $federatedCredentialPath = Join-Path ([System.IO.Path]::GetTempPath()) "$($credentialSubject.Name).json"
        Set-Content -Path $federatedCredentialPath -Value $federatedCredentialJson -Encoding utf8

        try {
            InvokeExternalCommand -CommandDescription "Create federated credential '$($credentialSubject.Name)'" -ScriptBlock {
                az ad app federated-credential create --id $ApplicationId --parameters $federatedCredentialPath --output none
            }
        }
        finally {
            Remove-Item -Path $federatedCredentialPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function CheckGitHubCLI {
    AssertCommandExists -Name 'gh'

    InvokeExternalCommand -CommandDescription 'Check GitHub CLI authentication' -ScriptBlock {
        gh auth status --hostname github.com
    }
}

function Set-GitHubEnvironment {
    param (
        [string]$Repository,
        [string]$EnvironmentName
    )

    InvokeExternalCommand -CommandDescription "Create or update GitHub environment '$EnvironmentName'" -ScriptBlock {
        gh api --method PUT "repos/$Repository/environments/$EnvironmentName" --silent
    }
}

function Set-GitHubRepositoryVariable {
    param (
        [string]$Repository,
        [string]$Name,
        [string]$Value
    )

    InvokeExternalCommand -CommandDescription "Set repository variable '$Name'" -ScriptBlock {
        gh variable set $Name --repo $Repository --body $Value
    }
}

function Set-GitHubEnvironmentVariable {
    param (
        [string]$Repository,
        [string]$EnvironmentName,
        [string]$Name,
        [string]$Value
    )

    InvokeExternalCommand -CommandDescription "Set environment variable '$Name'" -ScriptBlock {
        gh variable set $Name --repo $Repository --env $EnvironmentName --body $Value
    }
}

function Set-GitHubEnvironmentSecret {
    param (
        [string]$Repository,
        [string]$EnvironmentName,
        [string]$Name,
        [string]$Value
    )

    InvokeExternalCommand -CommandDescription "Set environment secret '$Name'" -ScriptBlock {
        $Value | gh secret set $Name --repo $Repository --env $EnvironmentName
    }
}

function CheckAZCLI {
    Write-Progress -Activity "Checking access via Azure CLI..."
    try {
        $accountInfo = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "You are not logged into Azure CLI. Please run 'az login' to log in." -ForegroundColor Red
            exit 1
        }

        $azureAccount = $accountInfo | ConvertFrom-Json
        Write-Host "You are logged in to Azure as '$($azureAccount.user.name)' for the subscription '$($azureAccount.user.name)'" -ForegroundColor Cyan
    }
    catch {
        Write-Host "An error occurred while checking Azure CLI login status." -ForegroundColor Red
        exit 1
    }
    Write-Progress -Activity "Checking access via Azure CLI..." -Completed
}

function CheckPACCLI {
    Write-Progress -Activity "Checking access via Power Platform CLI..."
    try {
        $environment = pac env who --json | ConvertFrom-Json
        $environmentName = $environment.FriendlyName
        $pacUserName = $environment.UserEmail

        Write-Host "You are currently authenticated to the Power Platform CLI as '$pacUserName' for the environment '$environmentName'" -ForegroundColor Cyan
    }
    catch {
        Write-Host "An error occurred while checking Power Platform CLI login status." -ForegroundColor Red
        exit 1
    }
    Write-Progress -Activity "Checking access via Power Platform CLI..." -Completed
}

function GetGitHubRepositoryName {
    param (
        [string[]]$remoteNames = @('origin')
    )

    foreach ($remoteName in $remoteNames) {
        $remoteUrl = git remote get-url $remoteName 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
            continue
        }

        if ($remoteUrl -match 'github\.com[:/]([^/]+)/(.+?)(\.git)?$') {
            $owner = $matches[1]
            $repository = $matches[2] -replace '\.git$', ''
            return "$owner/$repository"
        }
    }

    Write-Host "Unable to determine GitHub repository from remotes: $($remoteNames -join ', ')" -ForegroundColor Red
    exit 1
}

function GetGitHubRepositoryUrl {
    param (
        [string[]]$remoteNames = @('origin')
    )

    $repositoryName = GetGitHubRepositoryName -remoteNames $remoteNames
    return "https://github.com/$repositoryName"
}

function SaveGitHubReleaseAsset {
    param (
        [string]$repositoryName,
        [string]$assetName,
        [string]$outputFolder
    )

    if (-not (Test-Path -Path $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder > $null
    }

    $outputPath = Join-Path -Path $outputFolder -ChildPath $assetName
    if (Test-Path -Path $outputPath) {
        Write-Host "Using existing release asset '$outputPath'" -ForegroundColor Green
        return $outputPath
    }

    $releasesUrl = "https://api.github.com/repos/$repositoryName/releases?per_page=100"
    $headers = @{ "User-Agent" = "contoso-real-estate-power-platform-setup" }

    try {
        Write-Host "Downloading '$assetName' from GitHub releases for '$repositoryName'..." -ForegroundColor Green
        $releases = Invoke-RestMethod -Uri $releasesUrl -Headers $headers
        $asset = $releases |
            ForEach-Object { $_.assets } |
            Where-Object { $_.name -eq $assetName } |
            Select-Object -First 1

        if ($null -eq $asset) {
            throw "Release asset '$assetName' was not found in '$repositoryName'."
        }

        Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $outputPath
        Write-Host "Downloaded '$assetName' to '$outputPath'" -ForegroundColor Green
        return $outputPath
    }
    catch {
        Write-Host "Unable to download '$assetName'." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host "Download it manually from https://github.com/$repositoryName/releases?q=$($assetName -replace '_managed.zip$', '')&expanded=true and place it in '$outputFolder'." -ForegroundColor Yellow
        exit 1
    }
}

function GetSolutionPackageInfo {
    param (
        [string]$packagePath
    )

    if (-not (Test-Path -Path $packagePath)) {
        throw "Solution package '$packagePath' does not exist."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -Path $packagePath))
    try {
        $solutionEntry = $zip.Entries | Where-Object FullName -eq 'solution.xml' | Select-Object -First 1
        if ($null -eq $solutionEntry) {
            throw "Solution package '$packagePath' does not contain solution.xml."
        }

        $reader = [System.IO.StreamReader]::new($solutionEntry.Open())
        try {
            [xml]$solutionXml = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $manifest = $solutionXml.ImportExportXml.SolutionManifest
        return [pscustomobject]@{
            Path = $packagePath
            UniqueName = [string]$manifest.UniqueName
            Version = [string]$manifest.Version
            Managed = [int]$manifest.Managed
        }
    }
    finally {
        $zip.Dispose()
    }
}

function ReadSolutionDependencySource {
    Write-Host @"
Choose the source for solution packages:
[G] Download from GitHub releases in your origin repository
[B] Build from local source. This can take up to 20 minutes.
"@ -ForegroundColor Yellow

    while ($true) {
        $selection = Read-Host 'Enter G or B [G]'
        if ([string]::IsNullOrWhiteSpace($selection)) {
            return 'GitHubRelease'
        }

        switch ($selection.Trim().ToUpperInvariant()) {
            'G' { return 'GitHubRelease' }
            'B' { return 'LocalBuild' }
        }

        Write-Host "Invalid selection '$selection'. Enter G or B." -ForegroundColor Yellow
    }
}

function ClearSolutionDependencyFolder {
    param (
        [string]$outputFolder
    )

    if (Test-Path -Path $outputFolder) {
        Write-Host "Clearing solution dependency folder '$outputFolder'" -ForegroundColor Yellow
        Remove-Item -Path $outputFolder -Recurse -Force
    }

    New-Item -ItemType Directory -Path $outputFolder > $null
}

function RemovePathIfExists {
    param (
        [string]$path
    )

    if (Test-Path -Path $path) {
        Write-Host "Removing '$path'" -ForegroundColor Yellow
        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Host "Unable to fully remove '$path'. Continuing. $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function ClearSolutionPackageTransientFolders {
    param (
        [string]$solutionFolder
    )

    @('Metadata', 'SolutionPackager', 'SolutionPackagerLogs', 'obj') | ForEach-Object {
        RemovePathIfExists -path (Join-Path -Path $solutionFolder -ChildPath $_)
    }
}

function InvokeSolutionPackageBuild {
    param (
        [string]$solutionFolder,
        [int]$maxAttempts = 5
    )

    ClearSolutionPackageTransientFolders -solutionFolder $solutionFolder

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Host "Building solution at '$solutionFolder' (attempt $attempt/$maxAttempts)" -ForegroundColor Green
        dotnet build -c Release "$solutionFolder"
        if ($LASTEXITCODE -eq 0) {
            return
        }

        if ($attempt -ge $maxAttempts) {
            throw "Build failed for '$solutionFolder' after $maxAttempts attempts."
        }

        Write-Host "Build failed for '$solutionFolder'. Cleaning transient solution packaging folders before retrying." -ForegroundColor Yellow
        ClearSolutionPackageTransientFolders -solutionFolder $solutionFolder
        Start-Sleep -Seconds 3
    }
}

function InitializeSolutionDependencyAssets {
    param (
        [string]$repositoryName,
        [string]$outputFolder,
        [string]$repoRoot,
        [array]$dependencies
    )

    $source = ReadSolutionDependencySource
    ClearSolutionDependencyFolder -outputFolder $outputFolder

    if ($source -eq 'LocalBuild') {
        Write-Host 'Building dependency solution packages from local source. This can take up to 20 minutes.' -ForegroundColor Yellow
        $buildSolutions = @($dependencies | ForEach-Object { $_.BuildSolution } | Select-Object -Unique)
        & (Join-Path -Path $repoRoot -ChildPath 'scripts/build-release-packages.ps1') -Solution $buildSolutions
        if ($LASTEXITCODE -ne 0) {
            throw "Local dependency package build failed with exit code $LASTEXITCODE."
        }

        foreach ($dependency in $dependencies) {
            $outputPath = Join-Path -Path $outputFolder -ChildPath $dependency.AssetName
            if (-not (Test-Path -Path $dependency.LocalAssetPath)) {
                throw "Local dependency package was not created: '$($dependency.LocalAssetPath)'."
            }

            Write-Host "Copying locally built dependency '$($dependency.LocalAssetPath)' to '$outputPath'" -ForegroundColor Green
            Copy-Item -Path $dependency.LocalAssetPath -Destination $outputPath -Force
        }
    }
    else {
        foreach ($dependency in $dependencies) {
            SaveGitHubReleaseAsset `
                -repositoryName $repositoryName `
                -assetName $dependency.AssetName `
                -outputFolder $outputFolder > $null
        }
    }

    Write-Host 'Dependency solution package versions:' -ForegroundColor Cyan
    foreach ($dependency in $dependencies) {
        $packagePath = Join-Path -Path $outputFolder -ChildPath $dependency.AssetName
        $packageInfo = GetSolutionPackageInfo -packagePath $packagePath
        Write-Host "  $($dependency.AssetName): $($packageInfo.UniqueName) $($packageInfo.Version)" -ForegroundColor Cyan
    }

    return $source
}