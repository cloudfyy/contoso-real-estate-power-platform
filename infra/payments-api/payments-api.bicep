// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
param name string
param location string = resourceGroup().location
param tags object = {}
param storageAccountName string
param keyVaultName string
param appServicePlanName string
param applicationInsightsName string
param managedIdentity bool = !empty(keyVaultName) || storageManagedIdentity
param storageManagedIdentity bool = false
param apiApplicationID string
param virtualNetworkSubnetId string = ''

resource hostingPlan 'Microsoft.Web/serverfarms@2021-03-01' existing = {
  name: appServicePlanName
 
}

resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = if (!(empty(keyVaultName))) {
  name: keyVaultName
}

module api './api-host.bicep' = {
  name: 'payments-api-host'
  params: {
    name: name
    location: location
    tags: union(tags, { 'azd-service-name': 'payments-api' })
    applicationInsightsName  : applicationInsightsName
    storageAccountName: storageAccountName
    keyVaultName: keyVaultName
    apiApplicationID: apiApplicationID
    // Requires access to the vault
    // See https://learn.microsoft.com/en-us/azure/azure-resource-manager/managed-applications/key-vault-access
    apiAppicationSecret: 'set-by-postprovision-hook'
    managedIdentity: managedIdentity
    storageManagedIdentity: storageManagedIdentity
    virtualNetworkSubnetId: virtualNetworkSubnetId
    hostingPlanId: hostingPlan.id
    }
  }

var builtInStorageRoles = [
  builtInRoles.StorageBlobDataOwner
  builtInRoles.StorageQueueDataContributor
  builtInRoles.StorageTableDataContributor
  builtInRoles.StorageFileDataSMBShareContributor
]

module storageRoles '../core/security/role.bicep' = [for roleId in builtInStorageRoles: if (storageManagedIdentity) {
  name: 'storage-role-api-${roleId}'
  params: {
    principalId: api.outputs.identityPrincipalId
    roleDefinitionId: roleId
    principalType: 'ServicePrincipal'
  }
}]

var builtInRoles = loadJsonContent('../built-in-roles.json')

// Give the API access to read Key Vault secrets
resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  scope: keyVault
  name: guid(builtInRoles.KeyVaultSecretsUser, keyVault.id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions',builtInRoles.KeyVaultSecretsUser)
    principalId: api.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Allow the API setup endpoint to store Stripe secrets in Key Vault
resource keyVaultSecretsOfficerRole 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  scope: keyVault
  name: guid(builtInRoles.KeyVaultSecretsOfficer, keyVault.id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.KeyVaultSecretsOfficer)
    principalId: api.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output SERVICE_API_IDENTITY_PRINCIPAL_ID string = api.outputs.identityPrincipalId
output SERVICE_API_NAME string = name
output SERVICE_API_URI string = api.outputs.defaultHostName
