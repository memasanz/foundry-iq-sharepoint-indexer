#Requires -Version 7.0
<#
.SYNOPSIS
    One-shot orchestrator: deploys infra (Bicep), sets up the SharePoint app registration + RBAC,
    writes .env, then builds the multimodal ACL-trimmed index.

.DESCRIPTION
    Order of operations:
      1. az deployment group create (infra/main.bicep)  -> search + Foundry + model deployments.
      2. setup-app-registration.ps1                      -> SharePoint app, permissions, secret,
                                                            site grants, RBAC; appends .env.
      3. Write the resource values from step 1 into .env.
      4. pip install -r requirements.txt.
      5. python scripts/build_index.py build             -> datasource + index + skillset + indexer.
      6. python scripts/build_index.py status            -> poll until the indexer run finishes.

    Prerequisites: Azure CLI (logged in), PowerShell 7+, Python 3.9+, and the rights described in
    scripts/setup-app-registration.ps1 (admin consent + Owner/UAA on the resource group).

.EXAMPLE
    ./deploy.ps1 -ResourceGroup rg-spmm -Location eastus2 `
                 -SiteUrls "https://contoso.sharepoint.com/sites/knowledge"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $Location = 'eastus',
    [Parameter(Mandatory)] [string[]] $SiteUrls,
    [string] $BaseName = 'spmm',
    [switch] $SkipInfra,
    [switch] $SkipAppRegistration,
    [switch] $SkipIndex
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$envPath = Join-Path $repoRoot '.env'

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Deploy: SharePoint multimodal ACL search" -ForegroundColor Cyan
Write-Host " Resource group: $ResourceGroup  |  Location: $Location" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# --- 1. Infra ---------------------------------------------------------------
if (-not $SkipInfra) {
    Write-Host "`n[1/6] Creating resource group + deploying Bicep..." -ForegroundColor Green
    az group create -n $ResourceGroup -l $Location 1>$null
    $deploy = az deployment group create -g $ResourceGroup `
        -f (Join-Path $repoRoot 'infra/main.bicep') `
        -p baseName=$BaseName location=$Location `
        --query properties.outputs -o json | ConvertFrom-Json
}
else {
    Write-Host "`n[1/6] -SkipInfra set; reading existing deployment outputs..." -ForegroundColor Yellow
    $deploy = az deployment group show -g $ResourceGroup -n main `
        --query properties.outputs -o json | ConvertFrom-Json
}

$searchEndpoint        = $deploy.searchEndpoint.value
$searchPrincipalId     = $deploy.searchIdentityPrincipalId.value
$searchResourceId      = $deploy.searchServiceResourceId.value
$openAiEndpoint        = $deploy.openAiEndpoint.value
$foundryEndpoint       = $deploy.foundryEndpoint.value
$foundryResourceId     = $deploy.foundryResourceId.value

Write-Host "  searchEndpoint : $searchEndpoint" -ForegroundColor Gray
Write-Host "  foundryEndpoint: $foundryEndpoint" -ForegroundColor Gray

# --- 2/3. Write .env from infra outputs -------------------------------------
Write-Host "`n[2/6] Writing resource values to .env..." -ForegroundColor Green
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
Set-Content -Path $envPath -Value $envContent -Encoding utf8
Write-Host "  wrote $envPath" -ForegroundColor Gray

# --- 4. App registration + RBAC ---------------------------------------------
if (-not $SkipAppRegistration) {
    Write-Host "`n[3/6] Setting up SharePoint app registration + RBAC..." -ForegroundColor Green
    $developerId = az ad signed-in-user show --query id -o tsv
    & (Join-Path $repoRoot 'scripts/setup-app-registration.ps1') `
        -SearchIdentityPrincipalId $searchPrincipalId `
        -FoundryResourceId $foundryResourceId `
        -SiteUrls $SiteUrls `
        -SearchServiceResourceId $searchResourceId `
        -DeveloperPrincipalId $developerId `
        -EnvPath $envPath
}
else {
    Write-Host "`n[3/6] -SkipAppRegistration set; ensure SHAREPOINT_CONNECTION_STRING is in .env." -ForegroundColor Yellow
}

# --- 5. Python deps ---------------------------------------------------------
Write-Host "`n[4/6] Installing Python dependencies..." -ForegroundColor Green
python -m pip install -q -r (Join-Path $repoRoot 'requirements.txt')

# --- 6. Build index ---------------------------------------------------------
if (-not $SkipIndex) {
    Write-Host "`n[5/6] Building datasource + index + skillset + indexer..." -ForegroundColor Green
    python (Join-Path $repoRoot 'scripts/build_index.py') build

    Write-Host "`n[6/6] Polling indexer status (this can take several minutes)..." -ForegroundColor Green
    python (Join-Path $repoRoot 'scripts/build_index.py') status
}
else {
    Write-Host "`n[5/6] -SkipIndex set; run: python scripts/build_index.py build" -ForegroundColor Yellow
}

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Done. Explore results with notebooks/demo_retrieval_and_images.ipynb" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Cyan
