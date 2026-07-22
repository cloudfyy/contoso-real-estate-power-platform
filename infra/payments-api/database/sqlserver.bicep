// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
@description('The unique name of the application.')
param applicationUniqueName string

@description('The name of the SQL logical server.')
param serverName string

@description('The name of the SQL Database.')
param sqlDBName string

@description('Location for all resources.')
param location string = resourceGroup().location

param connectionStringKey string = 'AZURE-SQL-CONNECTION-STRING-${applicationUniqueName}'
param principalLoginName string
param principalId string
param keyVaultName string

resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: serverName
  location: location
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    restrictOutboundNetworkAccess: 'Disabled'
    administrators: {
        administratorType: 'ActiveDirectory'
        azureADOnlyAuthentication: true
        login: principalLoginName
        sid: principalId
    }
  }

}


resource database 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  parent: sqlServer
  name: sqlDBName
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
}

resource sqlAzureConnectionStringSercret 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = {
  parent: keyVault
  name: connectionStringKey
  properties: {
    value: '${connectionString};'
  }
}


resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  name: keyVaultName
}

var connectionString = 'Server=${sqlServer.properties.fullyQualifiedDomainName}; Database=${database.name};'
