# Contoso Real Estate Prerequisites

This document summarizes the software, tools, accounts, permissions, and cloud environments required to develop, build, and deploy the Contoso Real Estate Power Platform solution.

For a complete walkthrough, see [00-full-development-setup-instructions.md](./00-full-development-setup-instructions.md). For Azure API deployment details, see [01-azure-api-setup.md](./01-azure-api-setup.md). For CI/CD setup, see [04-ci-cd-setup.md](./04-ci-cd-setup.md) and [azure-devops/Setup.md](./azure-devops/Setup.md).

## Supported Workstation

Use a Windows development workstation for the full build and deployment flow.

Required workstation baseline:

- Windows 11.
- Local administrator rights to install developer tools.
- PowerShell 7 or Windows PowerShell with script execution allowed for repository setup scripts.
- Microsoft Edge or another modern browser with a separate work profile for Azure, Power Platform, GitHub, and Azure DevOps sign-in.

## Required Local Software

Install these tools before cloning and building the repository:

| Tool | Purpose |
| --- | --- |
| Visual Studio 2022 Community or higher | Builds .NET Framework, Power Platform solution, PCF, and MSBuild-based projects locally. |
| Visual Studio Code | Primary editor for repository work. |
| Git for Windows | Source control and command-line Git operations. |
| .NET SDK 10.0.x | Builds the Payments API Azure Functions project targeting `net10.0`. |
| .NET Framework 4.6.2 targeting pack and SDK | Required by Power Platform solution packaging projects such as `.cdsproj` projects. |
| .NET Framework 4.7.2 and 4.8 targeting packs and SDKs | Required by supporting Power Platform build tooling and existing project dependencies. |
| Node.js 18 and npm | Builds PCF controls, portal React UI, and model-driven app client hooks. Use Node.js 18 for this repository. |
| Azure CLI (`az`) | Azure authentication, resource inspection, Bicep commands, and setup scripts. |
| Azure Developer CLI (`azd`) | Provisions and deploys Azure resources defined by `azure.yaml`. |
| Bicep CLI | Builds and validates Bicep infrastructure templates. It can be installed through Azure CLI with `az bicep install`. |
| Power Platform CLI (`pac`) | Authenticates to Power Platform, imports solutions, lists environments, manages connections, and imports data. |
| GitHub CLI (`gh`) | Required only for GitHub workflow setup scripts. |
| Azure DevOps Azure CLI extension | Required for Azure DevOps variable group automation. Install with `az extension add --name azure-devops`. |

Recommended Visual Studio workloads:

- ASP.NET and web development.
- Azure development.
- Data storage and processing.

Recommended Visual Studio individual components:

- .NET SDK.
- .NET 10 SDK.
- .NET 8 runtime.
- .NET 6 runtime.
- .NET Framework 4.6.2 SDK and targeting pack.
- .NET Framework 4.7.2 SDK and targeting pack.
- .NET Framework 4.8 SDK and targeting pack.
- Windows 11 SDK.

## Accounts and Sign-In Requirements

You need access to these services:

- Azure subscription.
- Microsoft Entra tenant associated with the Azure subscription.
- Power Platform tenant in the same directory as the Azure subscription.
- Power Apps maker portal and Power Platform admin center.
- GitHub account if using GitHub workflows.
- Azure DevOps organization and project if using Azure DevOps pipelines.
- Stripe test account for Payments API validation.

Sign in locally before running setup or deployment scripts:

```powershell
az login
azd auth login
pac auth create
```

For GitHub workflow setup:

```powershell
gh auth login
```

For Azure DevOps variable group automation:

```powershell
az devops login --organization https://dev.azure.com/<organization-name>
```

## Azure Permissions

The Azure deployment provisions locked-down Azure resources and configures identity-based access. The deploying user should have sufficient permission to create resources and assign access.

Required Azure permissions:

- Contributor on the target subscription or resource group.
- User Access Administrator on the target subscription or resource group, used for role assignments.
- Key Vault Administrator or equivalent permission to manage Key Vault access and secrets during setup.
- Permission to create and update Entra application registrations and service principals.
- Permission to create resource groups, Function Apps, SQL resources, storage accounts, Key Vaults, App Configuration, and related monitoring resources.

Required subscription registration:

- `Microsoft.PowerPlatform` resource provider must be registered.

Useful checks:

```powershell
az account show --output table
az provider show --namespace Microsoft.PowerPlatform --query registrationState --output tsv
az bicep version
```

## Power Platform Environment Requirements

The sample uses separate Power Platform environments to keep managed solution dependencies explicit.

Required environments for development deployment:

- Core development Dataverse environment.
- Portal development Dataverse environment.

Power Platform requirements:

- Dataverse enabled in each environment.
- Appropriate security role for the deploying user.
- Power Platform CLI can list and authenticate to the target environments.
- Deployment service principal is added as an application user in each target Dataverse environment.
- The Portal environment has connected Power Platform connections for Dataverse and Contoso Stripe API before automated CD runs.
- A Power Pages website exists in the Portal environment before generating deployment configuration.

The Azure DevOps CD setup script can add the deployment application user to both target environments:

```powershell
./scripts/azure-devops/configure-cd-variable-group.ps1
```

The GitHub deployment setup script performs the equivalent setup for GitHub environments:

```powershell
./scripts/configure-github-deployment-environment.ps1 -azureEnv development
```

## Build Requirements

The repository contains multiple build surfaces:

- Payments API Azure Functions solution under `src/azure-api`, targeting .NET 10.
- Bicep infrastructure under `infra`.
- Power Platform managed solution packages for Custom Controls, Core, and Portal.
- PCF and TypeScript/React assets that require Node.js 18 and npm.

Local build prerequisites:

- `.NET SDK 10.0.x` available on `PATH`.
- Node.js 18 and npm available on `PATH`.
- Visual Studio MSBuild components installed for `.cdsproj`, `.pcfproj`, and .NET Framework builds.
- Power Platform build dependencies restored from NuGet and npm.
- Azure CLI with Bicep installed.

Useful build checks:

```powershell
dotnet --info
node --version
npm --version
az --version
az bicep version
pac --version
```

Primary build commands:

```powershell
dotnet restore src/azure-api/Contoso.API.Payments.sln
dotnet build src/azure-api/Contoso.API.Payments.sln --configuration Release
az bicep build --file infra/main.bicep
./scripts/build-release-packages.ps1 -Solution All -Clean
```

## Azure Deployment Requirements

Azure resources are deployed with Azure Developer CLI from the repository root.

Required before deployment:

- Azure CLI authenticated with the target tenant.
- Azure Developer CLI authenticated with the same account.
- Target subscription selected.
- Required Azure permissions granted.
- `Microsoft.PowerPlatform` provider registered.
- Azure location selected with available capacity.
- Power Platform username available for the `principalLoginName` infrastructure parameter.

Main deployment command:

```powershell
azd up --environment development
```

If infrastructure has already been provisioned and only the Payments API code needs deployment:

```powershell
azd deploy payments-api --environment development
```

Post-deployment scripts require the deployed Function App to be reachable from the setup machine and the current user to have enough permission to grant temporary access and call protected configuration endpoints.

Common post-deployment commands:

```powershell
./infra/scripts/configure-stripe-and-validate-payments.ps1
./infra/scripts/initialize-sql-via-function.ps1 -azureEnv development
./infra/scripts/write-payments-api-client-secret-to-key-vault.ps1 -azureEnv development
```

## GitHub CI/CD Requirements

GitHub workflows require:

- GitHub repository access with permission to manage variables, secrets, environments, and workflows.
- GitHub CLI authenticated locally.
- Entra application or service principal for PAC authentication.
- Federated credential configured for GitHub environment authentication.
- Power Platform application user added to target Dataverse environments.
- Required GitHub repository variables and environment secrets.

Build/validate setup:

```powershell
./scripts/configure-github-build-validate.ps1 -azureEnv development
```

Deployment environment setup:

```powershell
./scripts/configure-github-deployment-environment.ps1 -azureEnv development
```

## Azure DevOps CI/CD Requirements

Azure DevOps pipelines require:

- Azure DevOps organization and project.
- Repository pushed to Azure Repos or accessible from the pipeline.
- Power Platform Build Tools extension installed in the Azure DevOps organization.
- CI pipeline created from `azure-pipelines.yml` and named `contoso-real-estate-ci` if the CD pipeline references that name.
- CD pipeline created from `azure-pipelines-cd.yml`.
- Azure DevOps environment named `development`.
- Variable group named `contoso-real-estate-cd-development`.
- Azure CLI `azure-devops` extension installed locally for variable group automation.

Azure DevOps CD variable group setup:

```powershell
az extension add --name azure-devops
az devops login --organization https://dev.azure.com/<organization-name>
./scripts/azure-devops/configure-cd-variable-group.ps1 `
  -OrganizationUrl 'https://dev.azure.com/<organization-name>' `
  -Project '<project-name>' `
  -VariableGroupName 'contoso-real-estate-cd-development' `
  -DeploymentEnvironmentName 'development'
```

The variable group must include these values:

Non-secret variables:

- `PAC_DEPLOY_AZURE_TENANT_ID`
- `PAC_DEPLOY_CLIENT_ID`
- `PAC_DEPLOY_CORE_ENV_URL`
- `PAC_DEPLOY_PORTAL_ENV_URL`
- `PLUGIN_MANAGED_IDENTITY_APP_ID`
- `PAC_DEPLOY_CONFIG`
- `OVERRIDE_PLUGIN_MANAGED_IDENTITY_ID` if needed

Secret variables:

- `PAC_DEPLOY_CLIENT_SECRET`
- `PAYMENTS_API_CLIENT_SECRET`

## External Service Requirements

Stripe is required for the payment flow.

Required Stripe setup:

- Stripe test account.
- Stripe API key.
- Stripe webhook secret.
- Local access to run `./infra/scripts/configure-stripe-and-validate-payments.ps1` after Azure resources and the Payments API have been deployed.

## Quick Readiness Checklist

Use this checklist before building or deploying:

- Windows development workstation is ready.
- Visual Studio workloads and .NET Framework targeting packs are installed.
- .NET 10 SDK is installed.
- Node.js 18 and npm are installed.
- Git, Azure CLI, Azure Developer CLI, Power Platform CLI, and Bicep are installed.
- Azure CLI and Azure Developer CLI are authenticated to the correct tenant and subscription.
- Power Platform CLI is authenticated and can see the Core and Portal environments.
- Azure subscription has required permissions and `Microsoft.PowerPlatform` is registered.
- Core and Portal Dataverse environments exist.
- Portal environment has the required Dataverse and Contoso Stripe API connections.
- Stripe test account is available.
- GitHub or Azure DevOps pipeline prerequisites are configured if using CI/CD.