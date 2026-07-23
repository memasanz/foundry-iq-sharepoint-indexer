#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 1 (Developer). Provisions the Azure infrastructure via Bicep and writes the resource
    values (endpoints + model deployment names) to .env.

.DESCRIPTION
    Runs `az group create` + `az deployment group create` (infra/main.bicep) to create the Azure AI
    Search service (system managed identity + semantic ranker), the Foundry (AI Services) account,
    its project, and the model deployments (text-embedding-3-large, gpt-4.1-mini). Then writes the
    non-secret portion of .env from the deployment outputs and prints the values the admin needs for
    Phase 2 (scripts/setup-app-registration.ps1).

    Rights needed: **Contributor** on the resource group. No Entra or RBAC actions are performed
    here — those are the admin's Phase 2 (see README "Split deploy: developer vs. admin").

    Use -SkipDeploy to (re)write .env from an already-existing deployment without redeploying.

    > Region: default `eastus` (a Vision-capable region). Do NOT use `eastus2` — the Vision
    > multimodal-embeddings skill is unavailable there and the skillset build fails.

.EXAMPLE
    ./scripts/deploy-infra.ps1 -ResourceGroup rg-spmm -Location eastus

.OUTPUTS
    A hashtable of the deployment outputs (searchIdentityPrincipalId, foundryResourceId,
    searchServiceResourceId, endpoints) so an orchestrator can pass them on to Phase 2.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $Location = 'eastus',
    [string] $BaseName = 'spmm',
    [string] $EnvPath,
    # Skip the Bicep deployment; just read the existing 'main' deployment outputs and (re)write .env.
    [switch] $SkipDeploy
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $EnvPath) { $EnvPath = Join-Path $repoRoot '.env' }

if (-not $SkipDeploy) {
    Write-Host "Creating resource group '$ResourceGroup' ($Location) + deploying Bicep..." -ForegroundColor Green
    az group create -n $ResourceGroup -l $Location 1>$null
    az deployment group create -g $ResourceGroup -n main `
        -f (Join-Path $repoRoot 'infra/main.bicep') `
        -p baseName=$BaseName location=$Location 1>$null
}
else {
    Write-Host "-SkipDeploy set; reading existing 'main' deployment outputs..." -ForegroundColor Yellow
}

$deploy = az deployment group show -g $ResourceGroup -n main `
    --query properties.outputs -o json | ConvertFrom-Json

$searchEndpoint    = $deploy.searchEndpoint.value
$searchPrincipalId = $deploy.searchIdentityPrincipalId.value
$searchResourceId  = $deploy.searchServiceResourceId.value
$openAiEndpoint    = $deploy.openAiEndpoint.value
$foundryEndpoint   = $deploy.foundryEndpoint.value
$foundryResourceId = $deploy.foundryResourceId.value

# --- Write the non-secret portion of .env from the infra outputs -----------------------------
Write-Host "Writing resource values to .env..." -ForegroundColor Green
$envContent = @"
AZURE_SEARCH_ENDPOINT=$searchEndpoint
AZURE_SEARCH_API_VERSION=2026-05-01-preview
RESOURCE_PREFIX=sharepoint

AZURE_OPENAI_ENDPOINT=$openAiEndpoint
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-large
AZURE_OPENAI_EMBEDDING_MODEL=text-embedding-3-large
AZURE_OPENAI_EMBEDDING_DIMENSIONS=3072
AZURE_OPENAI_GPT_DEPLOYMENT=gpt-4.1-mini
AZURE_OPENAI_GPT_MODEL=gpt-4.1-mini

AZURE_AI_SERVICES_ENDPOINT=$foundryEndpoint
AZURE_AI_VISION_MODEL_VERSION=2023-04-15

SHAREPOINT_CONTAINER_NAME=defaultSiteLibrary
"@
Set-Content -Path $EnvPath -Value $envContent -Encoding utf8
Write-Host "  wrote $EnvPath" -ForegroundColor Gray

Write-Host "`n============ Hand these to the admin for Phase 2 ============" -ForegroundColor Cyan
Write-Host "  -SearchIdentityPrincipalId $searchPrincipalId"
Write-Host "  -FoundryResourceId         $foundryResourceId"
Write-Host "  -SearchServiceResourceId   $searchResourceId"
Write-Host "  (developer object id: run 'az ad signed-in-user show --query id -o tsv')"
Write-Host "============================================================" -ForegroundColor Cyan

# Emit the outputs so an orchestrator (deploy.ps1) can consume them.
[pscustomobject]@{
    searchEndpoint            = $searchEndpoint
    searchIdentityPrincipalId = $searchPrincipalId
    searchServiceResourceId   = $searchResourceId
    openAiEndpoint            = $openAiEndpoint
    foundryEndpoint           = $foundryEndpoint
    foundryResourceId         = $foundryResourceId
}
