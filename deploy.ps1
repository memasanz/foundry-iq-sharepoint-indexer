#Requires -Version 7.0
<#
.SYNOPSIS
    One-shot orchestrator for a "super admin" who holds every role. Runs the three deployment
    phases in order by calling the standalone per-phase scripts.

.DESCRIPTION
    Order of operations (each phase is its own reusable script — see README "Split deploy:
    developer vs. admin" to run them separately with least privilege):

      1. scripts/deploy-infra.ps1          (Phase 1, developer)  -> Bicep: search + Foundry +
                                                                    model deployments; writes .env.
      2. scripts/setup-app-registration.ps1 (Phase 2, admin)      -> SharePoint app, permissions,
                                                                    admin consent, secret, site
                                                                    grants, RBAC; appends .env.
      3. scripts/build-index.ps1           (Phase 3, developer)  -> pip install + datasource +
                                                                    index + skillset + indexer,
                                                                    then polls to completion.

    Running this single command requires the combined rights of all three phases: **Contributor**
    on the resource group, an **App/Privileged-Role admin**, and **Owner/User Access Administrator**.
    Use the -Skip* switches (or the individual scripts) to split the work — see the README.

    Prerequisites: Azure CLI (logged in), PowerShell 7+, Python 3.9+, and the rights described in
    scripts/setup-app-registration.ps1 (admin consent + Owner/UAA on the resource group).

    > Region: default `eastus` (Vision-capable). Do NOT deploy to `eastus2` — the Vision
    > multimodal-embeddings skill is unavailable there and the skillset build fails.

.EXAMPLE
    ./deploy.ps1 -ResourceGroup rg-spmm -Location eastus `
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

# --- 1. Infra (Phase 1: developer) — provision + write .env -----------------
$infraArgs = @{ ResourceGroup = $ResourceGroup; EnvPath = $envPath }
if ($SkipInfra) {
    Write-Host "`n[1/3] -SkipInfra set; (re)writing .env from existing deployment outputs..." -ForegroundColor Yellow
    $infraArgs.SkipDeploy = $true
}
else {
    Write-Host "`n[1/3] Provisioning infrastructure (Bicep)..." -ForegroundColor Green
    $infraArgs.Location = $Location
    $infraArgs.BaseName = $BaseName
}
& (Join-Path $repoRoot 'scripts/deploy-infra.ps1') @infraArgs | Out-Null

# Read the deployment outputs needed by Phase 2.
$deploy = az deployment group show -g $ResourceGroup -n main --query properties.outputs -o json | ConvertFrom-Json

# --- 2. App registration + RBAC (Phase 2: admin) ----------------------------
if (-not $SkipAppRegistration) {
    Write-Host "`n[2/3] Setting up SharePoint app registration + RBAC..." -ForegroundColor Green
    $developerId = az ad signed-in-user show --query id -o tsv
    & (Join-Path $repoRoot 'scripts/setup-app-registration.ps1') `
        -SearchIdentityPrincipalId $deploy.searchIdentityPrincipalId.value `
        -FoundryResourceId $deploy.foundryResourceId.value `
        -SiteUrls $SiteUrls `
        -SearchServiceResourceId $deploy.searchServiceResourceId.value `
        -DeveloperPrincipalId $developerId `
        -EnvPath $envPath
}
else {
    Write-Host "`n[2/3] -SkipAppRegistration set; ensure SHAREPOINT_CONNECTION_STRING is in .env." -ForegroundColor Yellow
}

# --- 3. Build index (Phase 3: developer) ------------------------------------
if (-not $SkipIndex) {
    Write-Host "`n[3/3] Building the index..." -ForegroundColor Green
    & (Join-Path $repoRoot 'scripts/build-index.ps1')
}
else {
    Write-Host "`n[3/3] -SkipIndex set; run: ./scripts/build-index.ps1" -ForegroundColor Yellow
}

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host " Done. Explore results with notebooks/demo_retrieval_and_images.ipynb" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Cyan
