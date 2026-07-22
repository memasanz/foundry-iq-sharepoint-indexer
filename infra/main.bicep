// -----------------------------------------------------------------------------
// Turnkey infrastructure for the multimodal, ACL-trimmed SharePoint index.
//
// Composes two modules:
//   1. modules/search.bicep   Azure AI Search (system MI, semantic ranker, keyless).
//   2. modules/foundry.bicep  Foundry (AI Services) account + project + model
//                             deployments (text embeddings + verbalization chat).
//
// The Foundry account also provides Content Understanding and Azure AI Vision
// multimodal embeddings (imageVector) - no extra deployment needed for those.
//
// Deploy:
//   az group create -n <rg> -l eastus2
//   az deployment group create -g <rg> -f infra/main.bicep -p infra/main.bicepparam
// -----------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Short base name used to derive resource names (lowercase alphanumerics/hyphens).')
param baseName string = 'spmm'

@description('Azure region. Model + Azure AI Vision multimodal-embedding availability varies by region; eastus2 is a safe default.')
param location string = resourceGroup().location

// --- Search ------------------------------------------------------------------
@description('Azure AI Search service name (globally unique, 2-60 lowercase chars).')
param searchServiceName string = toLower('${baseName}-search-${take(uniqueString(resourceGroup().id), 6)}')

@description('Search SKU.')
@allowed([
  'basic'
  'standard'
  'standard2'
  'standard3'
])
param searchSku string = 'basic'

// --- Foundry -----------------------------------------------------------------
@description('Foundry (AI Services) resource name (globally unique, 2-64 alphanumerics/hyphens).')
param foundryName string = toLower('${baseName}-foundry-${take(uniqueString(resourceGroup().id), 6)}')

@description('Foundry project name.')
param projectName string = '${baseName}-proj'

@description('Model deployments to create on the Foundry account: text embeddings (contentVector) + verbalization chat.')
param deployments array = [
  {
    name: 'text-embedding-3-large'
    model: { name: 'text-embedding-3-large', version: '1' }
    skuName: 'Standard'
    capacity: 50
  }
  {
    name: 'gpt-4.1-mini'
    model: { name: 'gpt-4.1-mini', version: '2025-04-14' }
    skuName: 'GlobalStandard'
    capacity: 50
  }
]

// -----------------------------------------------------------------------------

module search 'modules/search.bicep' = {
  name: 'search'
  params: {
    searchServiceName: searchServiceName
    location: location
    sku: searchSku
  }
}

module foundry 'modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    foundryName: foundryName
    projectName: projectName
    location: location
    deployments: deployments
  }
}

// --- Outputs (consumed by deploy.ps1 to write .env) --------------------------
@description('AZURE_SEARCH_ENDPOINT')
output searchEndpoint string = search.outputs.searchEndpoint

@description('Search managed-identity principal ID (passed to setup-app-registration.ps1 for RBAC).')
output searchIdentityPrincipalId string = search.outputs.searchIdentityPrincipalId

@description('Search service ARM resource ID (for developer data-plane role grants).')
output searchServiceResourceId string = search.outputs.searchServiceResourceId

@description('AZURE_OPENAI_ENDPOINT')
output openAiEndpoint string = foundry.outputs.openAiEndpoint

@description('AZURE_AI_SERVICES_ENDPOINT (Foundry account endpoint).')
output foundryEndpoint string = foundry.outputs.foundryEndpoint

@description('Foundry account ARM resource ID (-FoundryResourceId for the setup script).')
output foundryResourceId string = foundry.outputs.foundryResourceId

@description('Foundry project name.')
output projectName string = foundry.outputs.projectName
