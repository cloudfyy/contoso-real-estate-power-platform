// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
param storageAccountName string
param location string = resourceGroup().location
param privateEndpointSubnetId string
param blobPrivateDnsZoneId string
param queuePrivateDnsZoneId string
param tablePrivateDnsZoneId string
param filePrivateDnsZoneId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

var storagePrivateEndpoints = [
  {
    name: 'blob'
    groupId: 'blob'
    privateDnsZoneId: blobPrivateDnsZoneId
    privateDnsZoneConfigName: 'privatelink-blob-core-windows-net'
  }
  {
    name: 'queue'
    groupId: 'queue'
    privateDnsZoneId: queuePrivateDnsZoneId
    privateDnsZoneConfigName: 'privatelink-queue-core-windows-net'
  }
  {
    name: 'table'
    groupId: 'table'
    privateDnsZoneId: tablePrivateDnsZoneId
    privateDnsZoneConfigName: 'privatelink-table-core-windows-net'
  }
  {
    name: 'file'
    groupId: 'file'
    privateDnsZoneId: filePrivateDnsZoneId
    privateDnsZoneConfigName: 'privatelink-file-core-windows-net'
  }
]

resource privateEndpoints 'Microsoft.Network/privateEndpoints@2023-09-01' = [for endpoint in storagePrivateEndpoints: {
  name: '${storageAccountName}-${endpoint.name}-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${storageAccountName}-${endpoint.name}'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            endpoint.groupId
          ]
        }
      }
    ]
  }
}]

resource privateDnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = [for (endpoint, index) in storagePrivateEndpoints: {
  parent: privateEndpoints[index]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: endpoint.privateDnsZoneConfigName
        properties: {
          privateDnsZoneId: endpoint.privateDnsZoneId
        }
      }
    ]
  }
}]
