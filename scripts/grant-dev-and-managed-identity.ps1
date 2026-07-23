#Requires -Version 7.0
<#
.SYNOPSIS
    Grants the RBAC needed to build and run the index: the developer's two Azure AI Search
    data-plane roles, plus the search managed identity's "Cognitive Services User" role on the
    Foundry (Cognitive Services) resource.

.DESCRIPTION
    Kept separate from setup-app-registration.ps1 so the app-registration/consent work and the
    role assignments are independent concerns. This is an RBAC-only step.

    Developer (scoped to -SearchServiceResourceId):
      - Search Service Contributor    -> create the datasource / index / skillset / indexer
      - Search Index Data Contributor  -> upload documents and run ACL-trimmed queries

    Search managed identity (scoped to -FoundryResourceId):
      - Cognitive Services User        -> Content Understanding + verbalization chat + Azure AI
                                          Vision + text embeddings called by the skillset.

    All assignments are idempotent (existing ones are detected and left untouched). The caller needs
    **Owner** or **User Access Administrator** on both the search service and the Foundry resource.

    -SearchServiceResourceId, -SearchIdentityPrincipalId and -FoundryResourceId are read from the
    repo-root .env (AZURE_SEARCH_SERVICE_RESOURCE_ID / AZURE_SEARCH_IDENTITY_PRINCIPAL_ID /
    AZURE_FOUNDRY_RESOURCE_ID, written by deploy-infra.ps1) when not passed explicitly.
    Defaults to the signed-in user if -DeveloperPrincipalId is omitted.

.EXAMPLE
    # IDs read from .env (written by deploy-infra.ps1); grants the signed-in user
    ./scripts/grant-dev-and-managed-identity.ps1

.EXAMPLE
    # Admin grants a named developer in the split developer/admin model
    ./scripts/grant-dev-and-managed-identity.ps1 `
        -SearchServiceResourceId "<searchServiceResourceId from bicep output>" `
        -SearchIdentityPrincipalId "<searchIdentityPrincipalId from bicep output>" `
        -FoundryResourceId "<foundryResourceId from bicep output>" `
        -DeveloperPrincipalId <developer object id>
#>
[CmdletBinding()]
param(
    [string] $SearchServiceResourceId,
    [string] $SearchIdentityPrincipalId,
    [Alias('OpenAIResourceId')] [string] $FoundryResourceId,
    [string] $DeveloperPrincipalId,
    [ValidateSet('User', 'ServicePrincipal', 'Group')] [string] $DeveloperPrincipalType = 'User',
    # .env file to read the infra outputs from (written by deploy-infra.ps1).
    [string] $EnvPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $EnvPath) { $EnvPath = Join-Path $repoRoot '.env' }

function Get-EnvValue {
    param([string] $Path, [string] $Key)
    if (-not (Test-Path $Path)) { return $null }
    $line = Select-String -Path $Path -Pattern "^\s*$Key\s*=" | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line.Line -replace "^\s*$Key\s*=\s*", '').Trim()
}

if (-not $SearchServiceResourceId)   { $SearchServiceResourceId   = Get-EnvValue -Path $EnvPath -Key 'AZURE_SEARCH_SERVICE_RESOURCE_ID' }
if (-not $SearchIdentityPrincipalId) { $SearchIdentityPrincipalId = Get-EnvValue -Path $EnvPath -Key 'AZURE_SEARCH_IDENTITY_PRINCIPAL_ID' }
if (-not $FoundryResourceId)         { $FoundryResourceId         = Get-EnvValue -Path $EnvPath -Key 'AZURE_FOUNDRY_RESOURCE_ID' }
if (-not $SearchServiceResourceId)   { throw "SearchServiceResourceId not provided and AZURE_SEARCH_SERVICE_RESOURCE_ID not found in $EnvPath. Run scripts/deploy-infra.ps1 first, or pass -SearchServiceResourceId." }
if (-not $SearchIdentityPrincipalId) { throw "SearchIdentityPrincipalId not provided and AZURE_SEARCH_IDENTITY_PRINCIPAL_ID not found in $EnvPath. Run scripts/deploy-infra.ps1 first, or pass -SearchIdentityPrincipalId." }
if (-not $FoundryResourceId)         { throw "FoundryResourceId not provided and AZURE_FOUNDRY_RESOURCE_ID not found in $EnvPath. Run scripts/deploy-infra.ps1 first, or pass -FoundryResourceId." }

if (-not $DeveloperPrincipalId) {
    $DeveloperPrincipalId = az ad signed-in-user show --query id -o tsv
    Write-Host "No -DeveloperPrincipalId given; using the signed-in user ($DeveloperPrincipalId)." -ForegroundColor Yellow
}

function Grant-Rbac {
    param([string] $RoleName, [string] $PrincipalId, [string] $Scope, [string] $PrincipalTypeArg = 'ServicePrincipal')
    $existing = az role assignment list --assignee $PrincipalId --role $RoleName --scope $Scope --query "[0]" | ConvertFrom-Json
    if ($existing) { Write-Host "'$RoleName' already assigned on:`n  $Scope" -ForegroundColor Yellow; return }
    Write-Host "Assigning '$RoleName' to $PrincipalId on:`n  $Scope" -ForegroundColor Green
    az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $PrincipalTypeArg --role $RoleName --scope $Scope 1>$null
}

# --- Developer: search data-plane roles -------------------------------------
Grant-Rbac -RoleName 'Search Service Contributor'    -PrincipalId $DeveloperPrincipalId -Scope $SearchServiceResourceId -PrincipalTypeArg $DeveloperPrincipalType
Grant-Rbac -RoleName 'Search Index Data Contributor' -PrincipalId $DeveloperPrincipalId -Scope $SearchServiceResourceId -PrincipalTypeArg $DeveloperPrincipalType

# --- Search managed identity -> Foundry (Cognitive Services) ----------------
Grant-Rbac -RoleName 'Cognitive Services User' -PrincipalId $SearchIdentityPrincipalId -Scope $FoundryResourceId -PrincipalTypeArg 'ServicePrincipal'

Write-Host "`nDeveloper + search managed-identity roles granted. Role assignments can take ~1 min to propagate." -ForegroundColor Green
