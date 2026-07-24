// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
// https://learn.microsoft.com/en-us/graph/templates/quickstart-create-bicep-interactive-mode?tabs=CLI#prerequisites
extension 'br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:0.1.9-preview'

metadata description = 'Creates a an application registration and client service principal for an API'
param applicationUniqueName string
param applicationClientUniqueName string
param name string
param existingAppClientApplicationId string = ''
param existingAppClientObjectId string = ''
var newOrExisting = !empty(existingAppClientApplicationId) ? 'existing' : 'new'

// idempotent scopeId generator
var scopeId = guid(resourceGroup().id, applicationUniqueName, 'user_impersonation')
// idempotent appRoleId generator
var canCreateStripeSessionsAppRoleId = guid(resourceGroup().id, applicationUniqueName, 'CanCreateStripeSessions')
var canQueryPaymentsAppRoleId = guid(resourceGroup().id, applicationUniqueName, 'CanQueryPayments')
var canAddPaymentsAppRoleId = guid(resourceGroup().id, applicationUniqueName, 'CanAddPayments')
var canInitializePaymentsDatabaseAppRoleId = guid(resourceGroup().id, applicationUniqueName, 'CanInitializePaymentsDatabase')
var canConfigureStripeAppRoleId = guid(resourceGroup().id, applicationUniqueName, 'CanConfigureStripe')
var canValidatePaymentsConfigurationAppRoleId = guid(resourceGroup().id, applicationUniqueName, 'CanValidatePaymentsConfiguration')
var canReadPaymentsApiClientSecretAppRoleId = guid(resourceGroup().id, applicationUniqueName, 'CanReadPaymentsApiClientSecret')
var canWritePaymentsApiClientSecretAppRoleId = guid(resourceGroup().id, applicationUniqueName, 'CanWritePaymentsApiClientSecret')

// Define the Entra ID application registration
// https://learn.microsoft.com/en-us/graph/templates/reference/applications?view=graph-bicep-1.0
// https://learn.microsoft.com/en-us/graph/templates/quickstart-create-bicep-interactive-mode?tabs=CLI
// https://learn.microsoft.com/en-us/graph/templates/quickstart-create-bicep-zero-touch-mode?tabs=CLI
resource apiApplication 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: applicationUniqueName
  api: {
    knownClientApplications: []
    oauth2PermissionScopes: [
      {
        adminConsentDescription: 'Allow the Contoso Real Estate Payments API on behalf of the signed-in user.'
        adminConsentDisplayName: 'Access Contoso Real Estate Payments API'
        id:scopeId
        isEnabled: true
        type: 'User'
        userConsentDescription: 'Allow the application to access Contoso Real Estate Payments API on your behalf.'
        userConsentDisplayName: 'Access Contoso Real Estate Payments API'
        value: 'user_impersonation'
      }
    ]
    preAuthorizedApplications: []
  }
  appRoles: [
    {
      id: canCreateStripeSessionsAppRoleId
      allowedMemberTypes: [
        'User'
        'Application'
      ]
      description: 'Members of this role can create Stripe sessions.'
      displayName: 'Can Create Stripe Sessions'
      isEnabled: true 
      value: 'CanCreateStripeSessions'
    }
    {
      id: canQueryPaymentsAppRoleId
      allowedMemberTypes: [
        'User'
        'Application'
      ]
      description: 'Members of this role can query payments.'
      displayName: 'Can Query Payments'
      isEnabled: true
      value: 'CanQueryPayments'
    }
    {
      id: canAddPaymentsAppRoleId
      allowedMemberTypes: [
        'User'
        'Application'
      ]
      description: 'Members of this role can add payments.'
      displayName: 'Can Add Payments'
      isEnabled: true
      value: 'CanAddPayments'
    }
    {
      id: canInitializePaymentsDatabaseAppRoleId
      allowedMemberTypes: [
        'User'
        'Application'
      ]
      description: 'Members of this role can initialize the payments database.'
      displayName: 'Can Initialize Payments Database'
      isEnabled: true
      value: 'CanInitializePaymentsDatabase'
    }
    {
      id: canConfigureStripeAppRoleId
      allowedMemberTypes: [
        'User'
        'Application'
      ]
      description: 'Members of this role can configure Stripe payment settings.'
      displayName: 'Can Configure Stripe'
      isEnabled: true
      value: 'CanConfigureStripe'
    }
    {
      id: canValidatePaymentsConfigurationAppRoleId
      allowedMemberTypes: [
        'User'
        'Application'
      ]
      description: 'Members of this role can validate payments SQL and Key Vault configuration.'
      displayName: 'Can Validate Payments Configuration'
      isEnabled: true
      value: 'CanValidatePaymentsConfiguration'
    }
    {
      id: canReadPaymentsApiClientSecretAppRoleId
      allowedMemberTypes: [
        'User'
        'Application'
      ]
      description: 'Members of this role can read the Payments API client secret for deployment configuration.'
      displayName: 'Can Read Payments API Client Secret'
      isEnabled: true
      value: 'CanReadPaymentsApiClientSecret'
    }
    {
      id: canWritePaymentsApiClientSecretAppRoleId
      allowedMemberTypes: [
        'User'
        'Application'
      ]
      description: 'Members of this role can write the Payments API client secret for deployment configuration.'
      displayName: 'Can Write Payments API Client Secret'
      isEnabled: true
      value: 'CanWritePaymentsApiClientSecret'
    }
  ]
  description: name
  displayName: name
  requiredResourceAccess: [
    // Graph User.Read
    {
      resourceAppId: '00000003-0000-0000-c000-000000000000'
      resourceAccess: [
        {
          id: 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'
          type: 'Scope'
        }
      ]
    }
  ]
  signInAudience: 'AzureADMyOrg'
  tags: []
}

var apiApplicationResourceUri = 'api://${apiApplication.appId}'
// Define the Entra ID application registration with identifierUris
resource apiApplicationUpdate 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: applicationUniqueName
  displayName: name
  identifierUris: [
    apiApplicationResourceUri
  ]
}

// Add Service Principal
resource apiApplicationSp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: apiApplication.appId
  
}


// ------------------------------------------
// Define the client application registration
// ------------------------------------------
// If an existing application registration is updated it will throw an error due to the secret already existing
resource clientApp 'Microsoft.Graph/applications@v1.0' = if (newOrExisting == 'new') {
  uniqueName: applicationClientUniqueName
  displayName: 'Client for ${name}'
  requiredResourceAccess: [
		{
			resourceAppId: apiApplication.appId
			resourceAccess: [
				{
					id: scopeId // user_impersonation scope in application registration
					type: 'Scope'
				}
        {
					id: canCreateStripeSessionsAppRoleId // CanCreateStripeSessions app role to allow service principal to create stripe sessions from flows
					type: 'Role'
				}
        {
					id: canQueryPaymentsAppRoleId // CanQueryPayments app role to allow service principal to query payments from copilot studio for portal virtual assistant
					type: 'Role'
				}
        {
					id: canAddPaymentsAppRoleId // CanAddPayments app role to allow the virtual table managed identity scope to add payments
					type: 'Role'
				}
        {
          id: canInitializePaymentsDatabaseAppRoleId // CanInitializePaymentsDatabase app role to allow the setup script to initialize the database
          type: 'Role'
        }
        {
          id: canConfigureStripeAppRoleId // CanConfigureStripe app role to allow the setup script to configure Stripe secrets
          type: 'Role'
        }
        {
          id: canValidatePaymentsConfigurationAppRoleId // CanValidatePaymentsConfiguration app role to allow validation scripts to inspect configuration
          type: 'Role'
        }
        {
          id: canReadPaymentsApiClientSecretAppRoleId // CanReadPaymentsApiClientSecret app role to allow deployment scripts to read the connector client secret
          type: 'Role'
        }
        {
          id: canWritePaymentsApiClientSecretAppRoleId // CanWritePaymentsApiClientSecret app role to allow deployment scripts to write the connector client secret
          type: 'Role'
        }
			]
		}
  ]
}

var appClientKeyVaultSecretName = '${applicationClientUniqueName}-secret'
// Used when we want to assign roles to the client app to use from a custom connector service principal
resource clientSp 'Microsoft.Graph/servicePrincipals@v1.0' =  if (newOrExisting == 'new'){
  appId: clientApp.appId
}

// Add outputs from the deployment here, if needed.
output appId string = apiApplication.appId
output appObjectId string = apiApplication.id
output appServicePrincipalId string = apiApplicationSp.id
output appClientApplicationId string = newOrExisting == 'new' ? clientApp.appId : existingAppClientApplicationId
output appClientObjectId string = newOrExisting == 'new' ? clientApp.id : existingAppClientObjectId
output appClientKeyVaultSecretName string = appClientKeyVaultSecretName
output appResourceUri string = apiApplicationResourceUri
