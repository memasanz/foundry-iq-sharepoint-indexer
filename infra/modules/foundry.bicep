// -----------------------------------------------------------------------------
// Microsoft Foundry resource (Microsoft.CognitiveServices/accounts, kind =
// AIServices) + a Foundry project + model deployments used by the multimodal
// skillset:
//   - text-embedding-3-large  -> contentVector (3072-dim)
//   - a chat model            -> Content Understanding image VERBALIZATION
//
// The same AIServices account also serves Content Understanding and Azure AI
// Vision multimodal embeddings (imageVector, 1024-dim) via the Vision API - no
// separate deployment is required for those.
//
// Provisioning only. RBAC (search MI -> "Cognitive Services User") is handled by
// scripts/setup-app-registration.ps1.
// -----------------------------------------------------------------------------

@description('Name of the Foundry (AI Services) resource; also the API subdomain. 2-64 alphanumerics/hyphens.')
param foundryName string

@description('Name of the Foundry project to create.')
param projectName string

@description('Azure region. Model + Azure AI Vision multimodal-embedding availability varies by region.')
param location string

@description('Model deployments to create: [{ name, model: { name, version }, skuName, capacity }].')
param deployments array

@description('Disable key-based (local) auth so only Microsoft Entra ID (managed identity) is accepted.')
param disableLocalAuth bool = true

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: disableLocalAuth
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  name: projectName
  parent: foundry
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

// Deployments must be created one at a time (parallel creates on the same account are rejected).
@batchSize(1)
resource modelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = [
  for d in deployments: {
    parent: foundry
    name: d.name
    sku: {
      name: d.skuName
      capacity: d.capacity
    }
    properties: {
      model: {
        format: 'OpenAI'
        name: d.model.name
        version: d.model.version
      }
    }
  }
]

@description('Azure OpenAI-style endpoint (AZURE_OPENAI_ENDPOINT).')
output openAiEndpoint string = 'https://${foundryName}.openai.azure.com/'

@description('Foundry (AI Services) account endpoint (AZURE_AI_SERVICES_ENDPOINT).')
output foundryEndpoint string = foundry.properties.endpoint

@description('ARM resource ID of the Foundry account (for -FoundryResourceId in the setup script).')
output foundryResourceId string = foundry.id

@description('Name of the Foundry project.')
output projectName string = project.name
