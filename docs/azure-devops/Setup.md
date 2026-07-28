# Azure DevOps Setup

This guide documents how to push the local Git repository to an Azure DevOps Git repository and configure the initial CI pipeline.

## Target Azure DevOps Repository

- Organization: `icsudevopslab`
- Project: `contoso-real-estate`
- Repository: `contoso-real-estate`
- Repository URL: `https://dev.azure.com/icsudevopslab/contoso-real-estate/_git/contoso-real-estate`

## Prerequisites

Before pushing, make sure the Azure DevOps repository already exists and that your account has permission to contribute to it.

The Azure DevOps repository can be created from:

1. Open `https://dev.azure.com/icsudevopslab/contoso-real-estate`.
2. Go to **Repos**.
3. Create a new Git repository named `contoso-real-estate` if it does not already exist.
4. Leave the repository empty if you plan to push an existing local repository.

## Check Existing Remotes

Run this command from the local repository root:

```powershell
git remote -v
```

In this workspace, the existing remotes were:

- `origin`: GitHub fork
- `upstream`: Microsoft source repository
- `azure`: Azure DevOps repository

## Add or Update the Azure DevOps Remote

If the `azure` remote does not exist, add it:

```powershell
git remote add azure https://icsudevopslab@dev.azure.com/icsudevopslab/contoso-real-estate/_git/contoso-real-estate
```

If the `azure` remote already exists and needs to point to this repository, update it:

```powershell
git remote set-url azure https://icsudevopslab@dev.azure.com/icsudevopslab/contoso-real-estate/_git/contoso-real-estate
```

Verify the remote URL:

```powershell
git remote -v
```

## Push the Main Branch

Push the local `main` branch to Azure DevOps:

```powershell
git push azure main
```

If authentication is required, follow the browser or terminal sign-in prompt for Azure DevOps.

After a successful push, Git should show output similar to:

```text
* [new branch]      main -> main
```

## Verify in Azure DevOps

Open the repository in Azure DevOps:

```text
https://dev.azure.com/icsudevopslab/contoso-real-estate/_git/contoso-real-estate
```

Confirm that the expected repository content is visible, such as:

- `.github/`
- `docs/`
- `infra/`
- `src/`
- `azure.yaml`
- `README.md`

## Configure CI

This repository includes an Azure DevOps CI pipeline definition at the repository root:

```text
azure-pipelines.yml
```

The CI pipeline is based on the existing GitHub validation and release build configuration. It performs these checks:

- Restores and builds the Payments API solution in `Release` configuration.
- Compiles the Bicep entry template at `infra/main.bicep`.
- Builds all Power Platform solution packages by running `scripts/build-release-packages.ps1 -Solution All -Clean`.
- Publishes generated solution ZIP files as the `solution-packages` pipeline artifact.
- Publishes the compiled infrastructure template as the `infra` pipeline artifact.

### Required CI Configuration

The initial CI pipeline does not require Azure service connections, deployment environments, variable groups, or secrets. It only needs access to the Azure Repos Git repository and permission to run Microsoft-hosted agents.

Before creating the pipeline, confirm these settings in Azure DevOps:

1. Open `https://dev.azure.com/icsudevopslab/contoso-real-estate`.
2. Go to **Project settings**.
3. Go to **Pipelines** > **Settings**.
4. Confirm that pipeline creation and YAML pipelines are allowed for the project.
5. Confirm that Microsoft-hosted parallel jobs are available for the organization or project.
6. Go to **Project settings** > **Repositories**.
7. Select the `contoso-real-estate` repository.
8. Confirm that the pipeline creator has at least read permission on the repository.

The CI pipeline uses `windows-latest` because the Power Platform solution build depends on .NET/MSBuild behavior that matches the existing GitHub workflow. The pipeline installs .NET `10.0.x` by using the Azure Pipelines `UseDotNet@2` task.

### Commit and Push the Pipeline File

Make sure `azure-pipelines.yml` has been committed and pushed to Azure Repos before creating the pipeline from the Azure DevOps UI.

From the local repository root:

```powershell
git status --short
git add azure-pipelines.yml docs/azure-devops/Setup.md
git commit -m "Add Azure DevOps CI pipeline"
git push azure main
```

If the repository already contains other local changes that should not be included, stage only the CI-related files shown above.

### Create the CI Pipeline

To create the pipeline in Azure DevOps:

1. Open `https://dev.azure.com/icsudevopslab/contoso-real-estate`.
2. Go to **Pipelines**.
3. Select **New pipeline**.
4. Select **Azure Repos Git**.
5. Select the `contoso-real-estate` repository.
6. Select **Existing Azure Pipelines YAML file**.
7. Choose `/azure-pipelines.yml` from the `main` branch.
8. Review the pipeline and select **Run**.

If Azure DevOps asks for permission to access the repository or run the pipeline, approve the prompt for this pipeline.

### First Run Checks

After the first run starts, check these areas:

1. Open the pipeline run summary.
2. Confirm that the source branch is `main`.
3. Confirm that the agent image is `windows-latest`.
4. Confirm that the **Restore Payments API**, **Build Payments API**, **Build Bicep template**, and **Build Power Platform solution packages** steps complete successfully.
5. Open **Artifacts** from the completed run.
6. Confirm that these artifacts exist:

- `solution-packages`
- `infra`

### Trigger Configuration

The pipeline is configured to run on pushes to:

- `main`
- `release/*`
- `releases/*`

It also validates pull requests except those targeting release branches.

### Optional Repository Branch Policy

After the first CI run succeeds, configure a branch policy so pull requests into `main` must pass CI before completion:

1. Go to **Repos** > **Branches**.
2. Find the `main` branch.
3. Select the branch menu and choose **Branch policies**.
4. Under **Build validation**, select **Add build policy**.
5. Select the CI pipeline created from `/azure-pipelines.yml`.
6. Set **Trigger** to automatic.
7. Set **Policy requirement** to required.
8. Save the policy.

This keeps CI as a required quality gate for future pull requests.

## Configure CD

This repository includes a first Azure DevOps CD pipeline definition at the repository root:

```text
azure-pipelines-cd.yml
```

The initial CD pipeline is manual and deploys only the `development` environment. It downloads the `solution-packages` artifact from the CI pipeline, then imports the managed Power Platform solutions in the same order as the GitHub deployment workflow.

### CD Pipeline Behavior

The CD pipeline performs these deployment steps:

- Downloads the `solution-packages` artifact from the CI pipeline named `contoso-real-estate-ci`.
- Installs the Power Platform CLI by using `PowerPlatformToolInstaller@2`.
- Validates the required deployment variables.
- Injects managed identity and tenant configuration into the Core and Portal managed solution packages.
- Authenticates to the target Core or Portal Power Platform environment.
- Updates environment settings from `PAC_DEPLOY_CONFIG`.
- Resolves Portal connection references for Dataverse and Contoso Stripe API.
- Updates the Contoso Stripe API connection with the Payments API client secret.
- Imports each managed solution with `pac solution import`.
- Imports configured data files by using `pac data import`.

The deployment logic is implemented in:

```text
scripts/azure-devops/deploy-power-platform-solutions.ps1
```

The YAML file is responsible for pipeline orchestration only: selecting the CI artifact, installing PAC, passing variables from the variable group, validating configuration, and calling the deployment script once per solution.

The CD pipeline intentionally uses multiple Azure DevOps steps:

- `Validate CD configuration`
- `Deploy core / ContosoRealEstateCustomControls`
- `Deploy core / ContosoRealEstateCore`
- `Deploy portal / ContosoRealEstateCustomControls`
- `Deploy portal / ContosoRealEstateCore`
- `Deploy portal / ContosoRealEstatePortal`

This keeps the deployment order explicit and makes failures easier to locate in the pipeline run log.

The PowerShell script is split into these responsibilities:

- Validates all required deployment variables.
- Copies solution ZIP files from the downloaded CI artifact into a deployment working folder.
- Authenticates PAC to the Core or Portal Power Platform environment.
- Updates Power Platform environment settings from `PAC_DEPLOY_CONFIG`.
- Resolves Portal connection references for Dataverse and Contoso Stripe API.
- Updates the Contoso Stripe API connection with `PAYMENTS_API_CLIENT_SECRET`.
- Injects managed identity and tenant settings into Core and Portal managed solution packages.
- Imports managed solutions with `pac solution import`.
- Imports configured data files with `pac data import`.

The first version deploys these solutions sequentially:

```text
core   / ContosoRealEstateCustomControls
core   / ContosoRealEstateCore
portal / ContosoRealEstateCustomControls
portal / ContosoRealEstateCore
portal / ContosoRealEstatePortal
```

### Required CD Configuration

Before creating the CD pipeline, complete these Azure DevOps and Power Platform configuration steps.

### Install Azure DevOps Extension

Install the Microsoft Power Platform Build Tools extension in the Azure DevOps organization:

```text
https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.PowerPlatform-BuildTools
```

This extension provides the `PowerPlatformToolInstaller@2` task used by `azure-pipelines-cd.yml`.

### Name the CI Pipeline

The CD pipeline references the CI pipeline by name:

```yaml
source: contoso-real-estate-ci
```

In Azure DevOps, rename the CI pipeline created from `/azure-pipelines.yml` to:

```text
contoso-real-estate-ci
```

Path:

1. Go to **Pipelines**.
2. Open the CI pipeline.
3. Select the pipeline menu.
4. Select **Rename/move**.
5. Set the name to `contoso-real-estate-ci`.
6. Save the change.

### Create the Development Environment

The Azure DevOps CD setup script creates the deployment environment automatically when it is missing:

```text
development
```

If you prefer to create it manually, create an Azure DevOps environment for development deployments:

1. Go to **Pipelines** > **Environments**.
2. Select **New environment**.
3. Name it `development`.
4. Select **None** for the resource type.
5. Create the environment.

Do not add approval checks to `development` for the first run. Add approvals later for `testing` and `production`.

### Generate the Development Variable Group

The repository includes a helper script that creates or updates the Azure DevOps CD variable group:

```text
scripts/azure-devops/configure-cd-variable-group.ps1
```

Run it from the repository root after `azd provision` has completed and after the Portal environment has the required Dataverse and Contoso Stripe API connections:

```powershell
./scripts/azure-devops/configure-cd-variable-group.ps1 `
	-OrganizationUrl 'https://dev.azure.com/icsudevopslab' `
	-Project 'contoso-real-estate' `
	-VariableGroupName 'contoso-real-estate-cd-development' `
	-DeploymentEnvironmentName 'development'
```

The script reads Azure deployment outputs from `.azure/<environment>/.env`, lets you select the Core and Portal Dataverse environments, lets you select the Power Pages site, generates `PAC_DEPLOY_CONFIG`, reads the Payments API client secret, creates the Azure DevOps deployment environment when it is missing, creates or reuses the PAC deployment service principal, reads the existing Entra app client secret used by the Azure DevOps CD pipeline for PAC CLI authentication, adds the application user to both Dataverse environments, and writes the Azure DevOps variable group values.

Prerequisites on the local machine:

```text
az
az extension add --name azure-devops
pac
```

Sign in before running the script:

```powershell
az login
az devops login --organization https://dev.azure.com/icsudevopslab
pac auth create
```

To pass known values instead of selecting them interactively:

```powershell
./scripts/azure-devops/configure-cd-variable-group.ps1 `
	-CorePacDeployEnvUrl 'https://your-core.crm.dynamics.com' `
	-PortalPacDeployEnvUrl 'https://your-portal.crm.dynamics.com' `
	-PortalUrl 'https://your-site.powerappsportals.com'
```

The script does not create Entra client secrets. Create or rotate the Azure DevOps CD PAC CLI Entra app client secret outside this script, then pass it explicitly:

```powershell
./scripts/azure-devops/configure-cd-variable-group.ps1 `
	-PacDeployClientId '<application-client-id>' `
	-PacDeployClientSecret '<application-client-secret>'
```

You can also provide the secret through the current process environment:

```powershell
$env:PAC_DEPLOY_CLIENT_SECRET = '<application-client-secret>'
./scripts/azure-devops/configure-cd-variable-group.ps1 `
	-PacDeployClientId '<application-client-id>'
```

The target Azure DevOps variable group is:

```text
contoso-real-estate-cd-development
```

The script writes these non-secret variables:

```text
PAC_DEPLOY_AZURE_TENANT_ID
PAC_DEPLOY_CLIENT_ID
PAC_DEPLOY_CORE_ENV_URL
PAC_DEPLOY_PORTAL_ENV_URL
PLUGIN_MANAGED_IDENTITY_APP_ID
PAC_DEPLOY_CONFIG
OVERRIDE_PLUGIN_MANAGED_IDENTITY_ID
```

The script writes these secret variables:

```text
PAC_DEPLOY_CLIENT_SECRET
PAYMENTS_API_CLIENT_SECRET
```

`OVERRIDE_PLUGIN_MANAGED_IDENTITY_ID` is optional. Leave it empty unless the target environment needs a managed identity override.

If you prefer to configure the variable group manually, use this path:

1. Go to **Pipelines** > **Library**.
2. Select **Variable group**.
3. Name it `contoso-real-estate-cd-development`.
4. Add the variables listed below.
5. Select **Pipeline permissions**.
6. Allow the CD pipeline to use the variable group.

### Prepare the Entra Application

The first CD version uses service principal authentication for Power Platform CLI.

Prepare an Entra ID app registration and collect these values:

```text
PAC_DEPLOY_AZURE_TENANT_ID  = Tenant ID
PAC_DEPLOY_CLIENT_ID        = Application client ID
PAC_DEPLOY_CLIENT_SECRET    = Application client secret
```

Store `PAC_DEPLOY_CLIENT_SECRET` as a secret variable in the variable group.

### Add the Application User in Power Platform

Add the Entra application as an application user in each target Dataverse environment used by development deployment:

- Core development environment
- Portal development environment

Grant the application user enough permissions to import managed solutions, update environment settings, update connection references, and import data.

### Configure Environment URLs

Add the target Dataverse environment URLs to the variable group:

```text
PAC_DEPLOY_CORE_ENV_URL
PAC_DEPLOY_PORTAL_ENV_URL
```

The CD pipeline deploys `targetName: core` solutions to `PAC_DEPLOY_CORE_ENV_URL` and `targetName: portal` solutions to `PAC_DEPLOY_PORTAL_ENV_URL`.

### Configure Payments API Values

Add these values to the variable group:

```text
PLUGIN_MANAGED_IDENTITY_APP_ID
PAYMENTS_API_CLIENT_SECRET
```

`PLUGIN_MANAGED_IDENTITY_APP_ID` is injected into the Core managed solution.

`PAYMENTS_API_CLIENT_SECRET` is used to update the Portal Contoso Stripe API connection.

### Configure Portal Connections

Before running CD, create and connect these connections in the Portal development environment:

```text
Dataverse
Contoso Stripe API
```

The CD pipeline looks for connected Portal environment connections matching these API prefixes:

```text
/providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps
/providers/Microsoft.PowerApps/apis/shared_contoso-5fcontoso-20stripe-20api
```

If connection IDs are already known, they can also be placed in `PAC_DEPLOY_CONFIG` under the Portal deployment settings connection references.

### Configure PAC_DEPLOY_CONFIG

Add `PAC_DEPLOY_CONFIG` to the variable group as JSON. It should contain deployment settings for each solution that needs environment settings, connection references, or data imports.

Expected top-level keys:

```text
ContosoRealEstateCustomControls
ContosoRealEstateCore
ContosoRealEstatePortal
```

Each solution can include these sections:

```json
{
	"ContosoRealEstateCore": {
		"environmentSettings": {},
		"deploymentSettings": {},
		"data": []
	},
	"ContosoRealEstatePortal": {
		"environmentSettings": {},
		"deploymentSettings": {
			"ConnectionReferences": []
		},
		"data": []
	}
}
```

Keep this JSON valid and avoid trailing commas. If the value becomes too large for a variable group variable, move the JSON into a secure file or repository file and update the CD pipeline to read it from that location.

### Commit and Push the CD Pipeline File

From the local repository root:

```powershell
git status --short
git add azure-pipelines-cd.yml docs/azure-devops/Setup.md
git commit -m "Add Azure DevOps CD pipeline"
git push azure main
```

### Create the CD Pipeline

To create the CD pipeline in Azure DevOps:

1. Open `https://dev.azure.com/icsudevopslab/contoso-real-estate`.
2. Go to **Pipelines**.
3. Select **New pipeline**.
4. Select **Azure Repos Git**.
5. Select the `contoso-real-estate` repository.
6. Select **Existing Azure Pipelines YAML file**.
7. Choose `/azure-pipelines-cd.yml` from the `main` branch.
8. Save the pipeline.
9. Rename the pipeline to `contoso-real-estate-cd`.

### Run the First Development Deployment

Before running CD, make sure CI has completed successfully and published the `solution-packages` artifact.

To run CD:

1. Open the `contoso-real-estate-cd` pipeline.
2. Select **Run pipeline**.
3. Select the CI run to use for the `ci` pipeline resource if Azure DevOps prompts for a resource version.
4. Keep `stageAndUpgrade` set to `true` for the normal import path.
5. Start the run.

During the first run, verify these steps:

1. The pipeline downloads the `solution-packages` artifact.
2. The Power Platform CLI installer succeeds.
3. The Core target authenticates to `PAC_DEPLOY_CORE_ENV_URL`.
4. The Portal target authenticates to `PAC_DEPLOY_PORTAL_ENV_URL`.
5. Each solution deployment step runs in sequence.
6. Portal connection references resolve successfully during `Deploy portal / ContosoRealEstatePortal`.
7. Any configured data imports complete successfully in the related solution deployment step.

### Add Testing and Production Later

After development deployment works reliably, add separate variable groups and environments for testing and production:

```text
contoso-real-estate-cd-testing
contoso-real-estate-cd-production
testing
production
```

Add approval checks to `testing` and `production` from **Pipelines** > **Environments** before enabling those stages.

## Notes

- Pushing to Azure Repos does not remove or modify the existing GitHub remotes.
- GitHub Actions workflows under `.github/workflows/` are not automatically converted to Azure DevOps Pipelines.
- The initial Azure DevOps CD pipeline deploys only development. Add testing and production after development has been validated.