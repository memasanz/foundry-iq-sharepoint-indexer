// -----------------------------------------------------------------------------
// Azure AI Search service for the multimodal, ACL-trimmed SharePoint index.
//   - System-assigned managed identity (calls Azure OpenAI + Azure AI Vision keyless)
//   - Semantic ranker enabled
//   - Keyless / RBAC data-plane auth (recommended)
// -----------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Name of the Azure AI Search service (globally unique, 2-60 lowercase chars).')
param searchServiceName string

@description('Azure region for the search service.')
param location string = resourceGroup().location

@description('Search SKU. Basic or higher is required for managed identity + semantic ranker.')
@allowed([
  'basic'
  'standard'
  'standard2'
  'standard3'
])
param sku string = 'basic'

@description('Number of replicas.')
@minValue(1)
param replicaCount int = 1

@description('Number of partitions.')
@allowed([
  1
  2
  3
  4
  6
  12
])
param partitionCount int = 1

@description('Semantic ranker plan. "standard" is billed per usage.')
@allowed([
  'free'
  'standard'
])
param semanticSearch string = 'standard'

@description('When true, only Microsoft Entra ID (RBAC) auth is allowed on the data plane (recommended).')
param disableLocalAuth bool = true

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchServiceName
  location: location
  sku: {
    name: sku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: replicaCount
    partitionCount: partitionCount
    hostingMode: 'Default'
    publicNetworkAccess: 'enabled'
    disableLocalAuth: disableLocalAuth
    authOptions: disableLocalAuth ? null : {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    semanticSearch: semanticSearch
  }
}

@description('Search service endpoint (AZURE_SEARCH_ENDPOINT).')
output searchEndpoint string = 'https://${search.name}.search.windows.net'

@description('System-assigned managed identity principal ID of the search service.')
output searchIdentityPrincipalId string = search.identity.principalId

@description('ARM resource ID of the search service (for developer data-plane role grants).')
output searchServiceResourceId string = search.id
