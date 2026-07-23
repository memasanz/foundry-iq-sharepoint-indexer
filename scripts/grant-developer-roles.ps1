#Requires -Version 7.0
<#
.SYNOPSIS
    Grants a developer (or service principal / group) the two Azure AI Search data-plane roles needed
    to build and query the index: Search Service Contributor + Search Index Data Contributor.

.DESCRIPTION
    Kept separate from setup-app-registration.ps1 so the app-registration/consent work and the
    developer's personal RBAC are independent concerns. This is an RBAC-only step: the caller needs
    **Owner** or **User Access Administrator** on the search service.

    - Search Service Contributor    -> create the datasource / index / skillset / indexer
    - Search Index Data Contributor  -> upload documents and run ACL-trimmed queries

    Both are scoped to -SearchServiceResourceId (a Bicep output). Existing assignments are detected
    and left untouched (idempotent).

    Defaults to the signed-in user if -DeveloperPrincipalId is omitted.

.EXAMPLE
    # SearchServiceResourceId read from .env (written by deploy-infra.ps1); grants the signed-in user
    ./scripts/grant-developer-roles.ps1

.EXAMPLE
    # Admin grants a named developer in the split developer/admin model
    ./scripts/grant-developer-roles.ps1 `
        -SearchServiceResourceId "<searchServiceResourceId from bicep output>" `
        -DeveloperPrincipalId <developer object id>
#>
[CmdletBinding()]
param(
    [string] $SearchServiceResourceId,
    [string] $DeveloperPrincipalId,
    [ValidateSet('User', 'ServicePrincipal', 'Group')] [string] $DeveloperPrincipalType = 'User',
    # .env file to read AZURE_SEARCH_SERVICE_RESOURCE_ID from (written by deploy-infra.ps1).
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

if (-not $SearchServiceResourceId) { $SearchServiceResourceId = Get-EnvValue -Path $EnvPath -Key 'AZURE_SEARCH_SERVICE_RESOURCE_ID' }
if (-not $SearchServiceResourceId) { throw "SearchServiceResourceId not provided and AZURE_SEARCH_SERVICE_RESOURCE_ID not found in $EnvPath. Run scripts/deploy-infra.ps1 first, or pass -SearchServiceResourceId." }

if (-not $DeveloperPrincipalId) {
    $DeveloperPrincipalId = az ad signed-in-user show --query id -o tsv
    Write-Host "No -DeveloperPrincipalId given; using the signed-in user ($DeveloperPrincipalId)." -ForegroundColor Yellow
}

function Grant-Rbac {
    param([string] $RoleName, [string] $PrincipalId, [string] $Scope, [string] $PrincipalTypeArg)
    $existing = az role assignment list --assignee $PrincipalId --role $RoleName --scope $Scope --query "[0]" | ConvertFrom-Json
    if ($existing) { Write-Host "'$RoleName' already assigned on:`n  $Scope" -ForegroundColor Yellow; return }
    Write-Host "Assigning '$RoleName' to $PrincipalId on:`n  $Scope" -ForegroundColor Green
    az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $PrincipalTypeArg --role $RoleName --scope $Scope 1>$null
}

Grant-Rbac -RoleName 'Search Service Contributor'    -PrincipalId $DeveloperPrincipalId -Scope $SearchServiceResourceId -PrincipalTypeArg $DeveloperPrincipalType
Grant-Rbac -RoleName 'Search Index Data Contributor' -PrincipalId $DeveloperPrincipalId -Scope $SearchServiceResourceId -PrincipalTypeArg $DeveloperPrincipalType

Write-Host "`nDeveloper search data-plane roles granted. Role assignments can take ~1 min to propagate." -ForegroundColor Green
