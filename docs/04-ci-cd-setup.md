# Setting up CI/CD

This project is set up for GitHub continuous integration and deployment workflows.

The Power Platform deployment workflows use the Power Platform CLI (pac) and connect using GitHub [federated identity credentials](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust?pivots=identity-wif-apps-methods-azp).

> [!IMPORTANT]
> You can connect to Power Platform using an Application ID and Secret, but federated identity credentials avoid the need to store client secrets in GitHub.

## Workflow scope

The GitHub workflows cover two parts of the repository:

- **Power Platform solution CI/CD** - The `Build`, `Validate`, and `Deploy` workflows build solution packages, run Power Platform Solution Checker, create releases, and import managed solutions into target Power Platform environments.
- **Azure API and infrastructure validation** - The reusable `_Validate Azure API and Infrastructure` workflow restores and builds the Payments API .NET solution with .NET 10, then compiles `infra/main.bicep` to validate the Bicep template. This reusable workflow is called by both `Build` and `Validate`.

Azure resource provisioning and Payments API deployment are still performed through Azure Developer CLI (`azd`) using `azure.yaml`:

```powershell
azd up --environment development
azd deploy payments-api --environment development
```

The GitHub validation workflow compiles the locked-down infrastructure template, but it does not deploy Azure resources or connect directly to private SQL, Key Vault, or Storage endpoints.

## Build and validate prerequisites

Before running `Build` or `Validate`, configure the repository settings used by the workflows:

- `Validate` runs the Power Platform solution build checks plus the Azure API/Bicep validation workflow. It does not require repository variables or Power Platform secrets.
- `Build` runs a solution matrix and Power Platform Solution Checker, so it requires the `SOLUTIONS_CONFIG` repository variable plus the `solution-checker` GitHub environment and PAC authentication secrets.

Run the helper script once after `azd provision` or `azd up` to configure the GitHub settings required by `Build`:

```powershell
./scripts/configure-github-build-validate.ps1 `
    -azureEnv development `
    -PacDeployEnvUrl 'https://<core-dev-org>.crm.dynamics.com'
```

Use the Core Dev Dataverse environment URL for `-PacDeployEnvUrl` when configuring the shared Build workflow Solution Checker environment. This value becomes the `PAC_DEPLOY_ENV_URL` secret on the `solution-checker` GitHub environment. Do not use the Portal Dev URL or rely on the current local PAC environment unless you intentionally pass `-UseCurrentPacEnvironment`. The script uses the GitHub CLI (`gh`) and the `origin` remote to detect the repository. It generates `SOLUTIONS_CONFIG` from the solution package definitions in `scripts/common/solution-packages.ps1`, and reads `AZURE_TENANT_ID` and `ENTRA_API_CLIENT_APP_ID` from the selected azd environment. You can still override any value explicitly:

```powershell
./scripts/configure-github-build-validate.ps1 `
    -azureEnv development `
    -PacDeployAzureTenantId '<tenant-id>' `
    -PacDeployClientId '<application-client-id>' `
    -PacDeployEnvUrl 'https://<core-dev-org>.crm.dynamics.com' `
    -PowerPlatformApplicationUserRole 'System Customizer'
```

The helper script adds the PAC client application as a Power Platform application user in the Core Dev Dataverse environment and creates or confirms the GitHub federated credentials for the `solution-checker` environment, including the repository slug subject and the ID-qualified subject emitted by GitHub Actions/PAC. The application user role defaults to `System Customizer`; pass `-PowerPlatformApplicationUserRole` only if your environment requires a different role.

The helper script covers the Build/Validate prerequisites only:

- Creates or updates the `solution-checker` GitHub environment.
- Sets the `SOLUTIONS_CONFIG` repository variable.
- Sets `PAC_DEPLOY_AZURE_TENANT_ID`, `PAC_DEPLOY_CLIENT_ID`, and the Core Dev `PAC_DEPLOY_ENV_URL` as secrets on the `solution-checker` environment.
- Adds `PAC_DEPLOY_CLIENT_ID` as a Power Platform application user in the Core Dev Dataverse environment.
- Creates or confirms the Entra ID federated credential for the `solution-checker` GitHub environment.

It does not configure the `development`, `testing`, or `production` deployment environments, and it does not generate `PAC_DEPLOY_CONFIG`. Those are deployment workflow settings.

For the deployment workflow to deploy to each Power Platform environment, the following setup is required:

- GitHub environments created (**GitHub** -> **Settings** -> **Environments**)
    - **development** - Environment that the releases are deployed to first to stabilize a release. Integration and UI tests are performed in this environment.
    - **testing** - Environment that the releases are deployed to after a release is stabilized, for acceptance testing.
    - **production** - Final production environment

- Environment secrets added to each environment (Add environment secret)
    - `PAC_DEPLOY_AZURE_TENANT_ID` - The Azure Tenant ID of the Power Platform Tenant being deployed to
    - `PAC_DEPLOY_CLIENT_ID` - The Application ID of an Entra ID application registration that has been added to the target Power Platform environment as an application user.
    - `PAC_DEPLOY_ENV_URL` - The url of the target environment e.g. https://org123.crm.dynamics.com

- Environment variables are needed to provide deployment settings:
    - `PAC_DEPLOY_CONFIG` - The deployment settings json that contains the environment variables, connection references, and data files to import for each solution
    

Approvals are used to gate each environment deployment. 
> [!NOTE]
> This feature is only available to **public** repos on Pro or Team based accounts. 

## Adding Environment Protection Rules

Perform the following steps for each deployment GitHub environment (`development`, `testing`, `production`) after running the federated credential script below. A minimum of `development` must be created to use the deployment workflow. The `solution-checker` environment is configured by `scripts/configure-github-build-validate.ps1` for the Build workflow.

1. Go to **Settings | Environments**
1. Select **New environment**
1. Give the environment a name (e.g. `development`, `testing`, `production`)
1. Check **Require reviewers**
1. Add one or more required reviewers by searching for their names
1. Select **Save protection rules**
1. Repeat for other environments

## Configuring Federated Identity Credentials

GitHub workflow pac commands can connect using:
```
pac auth create --githubFederated --tenant ${{ secrets.PAC_DEPLOY_AZURE_TENANT_ID }} --applicationId ${{ secrets.PAC_DEPLOY_CLIENT_ID }} --environment ${{ secrets.PAC_DEPLOY_ENV_URL }}
```
Federated credentials must be added to Entra ID to establish a trust. The deployment setup script creates or updates the GitHub environment, sets the PAC deployment secrets, creates or reuses the Entra ID application, creates or confirms the GitHub environment federated credential, and grants Key Vault access.

👉 To set up these credentials, drag the script `/src/core/solution/deployment-scripts/3-github-environment-add-fed-creds.ps1` into your VSCode terminal and press **ENTER**.

To perform these steps manually for a deployment environment, use the following steps:
1. Authenticate the [Power Platform CLI](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.powerplatform-vscode) and select the target Power Platform environment:
    ```powershell
    pac auth create
    
    pac env list
    
    # Alternatively use the VSCode extension to authenticate and select the environment
    pac env select --environment <Environment Name>
    ```

1. Install the Azure CLI by following the instructions provided in the [official Azure CLI documentation for your operating system](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli).

1. Drag the script [/src/core/solution/deployment-scripts/3-github-environment-add-fed-creds.ps1](/src/core/solution/deployment-scripts/3-github-environment-add-fed-creds.ps1) into your VSCode terminal, and press **ENTER** to set up the GitHub CI/CD authentication. 

## Manual Steps

The federated credential script performs the following steps for each deployment environment. The `solution-checker` environment is configured by `scripts/configure-github-build-validate.ps1`.

1. Log in to your Azure account by running the following command and following the prompts:

    ```powershell
    az login
    ```

    This will open a browser window where you can authenticate with your Azure account.

1. Create or reuse an Entra ID application for that GitHub environment.

    ```powershell
    $environmentName = "development"
    
    $tenantId = az account show --query tenantId -o tsv
    . ./infra/scripts/function-get-environment-variables.ps1
    $envVars = GetEnvironmentVariables -azureEnv $environmentName
    $environmentDetails = pac env who --json | ConvertFrom-Json
    $environmentUrl = $environmentDetails.OrgUrl.TrimEnd('/')
    $spnName = "cre-github-workflows-$environmentName"
    $remoteUrl = git remote get-url origin
    if ($remoteUrl -match "github\.com[:/](.+?)/(.+?)(\.git)?$") {$repoName = $matches[1] + "/" + $matches[2] }

    $applicationId = az ad sp list --display-name $spnName --query "[0].appId" -o tsv
    if (-not $applicationId) {
        pac admin create-service-principal --name $spnName
        $applicationId = az ad sp list --display-name $spnName --query "[0].appId" -o tsv
    }
    ```
    
1. Add the application as an application user to the target Power Platform environment:

    ```powershell
    pac admin assign-user --environment $environmentUrl --application-user --user $applicationId --role "System Administrator"
    ```

1. Register the application id as federated credentials for GitHub. Use a JSON file when running from PowerShell so Azure CLI receives valid JSON:

    ```powershell
    $federatedCredential = @{
        name = $spnName
        issuer = 'https://token.actions.githubusercontent.com'
        subject = "repo:${repoName}:environment:${environmentName}"
        description = "GitHub access for the environment $environmentName and repo $repoName"
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Depth 5

    $federatedCredentialPath = Join-Path ([System.IO.Path]::GetTempPath()) "$spnName.json"
    Set-Content -Path $federatedCredentialPath -Value $federatedCredential -Encoding utf8
    az ad app federated-credential create --id $applicationId --parameters $federatedCredentialPath --output none
    Remove-Item -Path $federatedCredentialPath -Force
    ```

1. Grant the application access to the deployed Key Vault so Dataverse can read Key Vault-backed environment variable secrets during solution import:

    ```powershell
    az role assignment create --role "Key Vault Secrets User" --assignee $applicationId --scope /subscriptions/$($envVars.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($envVars.AZURE_RESOURCE_GROUP)/providers/Microsoft.KeyVault/vaults/$($envVars.AZURE_KEY_VAULT_NAME)
    az role assignment create --role "Key Vault Reader" --assignee $applicationId --scope /subscriptions/$($envVars.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($envVars.AZURE_RESOURCE_GROUP)/providers/Microsoft.KeyVault/vaults/$($envVars.AZURE_KEY_VAULT_NAME)
    ```

1. Create or update the GitHub environment and set the PAC deployment secrets:

    ```powershell
    gh api --method PUT "repos/$repoName/environments/$environmentName" --silent
    $tenantId | gh secret set PAC_DEPLOY_AZURE_TENANT_ID --repo $repoName --env $environmentName
    $applicationId | gh secret set PAC_DEPLOY_CLIENT_ID --repo $repoName --env $environmentName
    $environmentUrl | gh secret set PAC_DEPLOY_ENV_URL --repo $repoName --env $environmentName
    ```

## Deployment Settings

👉 To setup the Deployment Config, drag the script `src\core\solution\deployment-scripts\4-github-environment-create-deployment-settings.ps1` into your VSCode terminal and press **ENTER**.

This script will prompt you to create an environment variable called `PAC_DEPLOY_CONFIG` for each environment.

The variable must be in the form:

```json
{
"ContosoRealEstateCore": {
    "data": [
    "reference-data.zip",
    "sample-data.zip"
    ],
    "deploymentSettings": {
    ...
    }
},
"ContosoRealEstatePortal": {
    "data": [],
    "deploymentSettings": {
    ...
    }
}
}
```

This script will also prompt you to create an environment secret called `PLUGIN_MANAGED_IDENTITY_APP_ID` containing the Application ID of the Payment API Client that the C# Plugin Virtual Table Provider will use to connect to the Payment API. This is injected into the solution before it is deployed because at this time the Managed Identity Application Id and Tenant Id are not configurable using `deploymentSettings.json`.

## Set repository variables

The `Build` workflow needs the `SOLUTIONS_CONFIG` repository variable to expand its solution matrix. The helper script creates this variable automatically from the solution package definitions in `scripts/common/solution-packages.ps1`, so you should not need to maintain a separate JSON copy in GitHub.

To preview the generated value locally, run:

```powershell
. ./scripts/common/solution-packages.ps1
Get-GitHubSolutionsConfigJson
```

If you need a custom matrix, provide a JSON file to the helper script:

```powershell
./scripts/configure-github-build-validate.ps1 -azureEnv development -SolutionsConfigPath ./path/to/solutions-config.json
```

The optional `ACTIONS_STEP_DEBUG` repository variable can still be set manually to `true` or `false` from **GitHub** -> **Settings** -> **Secrets and Variables** -> **Actions** -> **Variables**.

## Local package build and release helpers

Use the repository build helper to create and validate local solution packages:

```powershell
./scripts/build-release-packages.ps1
```

The helper builds Controls, Core, and Portal solution packages, prints timing for each solution, and verifies that each zip contains the expected solution version and key package entries. Useful options:

```powershell
./scripts/build-release-packages.ps1 -Solution Core
./scripts/build-release-packages.ps1 -UseExistingPackages
./scripts/build-release-packages.ps1 -Clean
./scripts/build-release-packages.ps1 -Clean -CleanNodeModules
./scripts/build-release-packages.ps1 -VerifyOnly
```

To publish GitHub releases from the current solution versions, use the release helper. Always preview first:

```powershell
./scripts/publish-solution-releases.ps1 -WhatIf
```

The release helper reads each current solution version, increments the third version segment, resets the fourth segment to `0`, builds and verifies packages, commits the version changes, pushes the branch, and creates GitHub releases with managed and unmanaged zip assets. Examples:

```powershell
./scripts/publish-solution-releases.ps1 -Solution Core -WhatIf
./scripts/publish-solution-releases.ps1 -Solution Core
./scripts/publish-solution-releases.ps1 -Repository <owner>/<repo>
./scripts/publish-solution-releases.ps1 -Clean
```

