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
git add azure-pipelines.yml docs/azure-devops/README.md
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

## Notes

- Pushing to Azure Repos does not remove or modify the existing GitHub remotes.
- GitHub Actions workflows under `.github/workflows/` are not automatically converted to Azure DevOps Pipelines.
- The initial Azure DevOps pipeline is CI only. Deployment stages can be added separately after the CI pipeline is running reliably.