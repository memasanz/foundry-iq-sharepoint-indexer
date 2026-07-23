#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 3 (Developer). Installs the Python dependencies and builds the search objects
    (datasource + index + skillset + indexer), then polls the indexer to completion.

.DESCRIPTION
    A thin wrapper over scripts/build_index.py that reads .env (which must already contain the
    resource endpoints from Phase 1 and SHAREPOINT_CONNECTION_STRING from Phase 2).

    Rights needed: the two data-plane roles the admin granted in Phase 2 — **Search Service
    Contributor** + **Search Index Data Contributor** on the search service.

    This script does NOT touch .env, so it is safe to run repeatedly without clobbering the
    admin-supplied SHAREPOINT_CONNECTION_STRING.

.EXAMPLE
    ./scripts/build-index.ps1

.EXAMPLE
    ./scripts/build-index.ps1 -SkipInstall -NoPoll    # deps already installed; don't block on status
#>
[CmdletBinding()]
param(
    # Skip 'pip install -r requirements.txt' (deps already present).
    [switch] $SkipInstall,
    # Build only; do not poll indexer status afterward.
    [switch] $NoPoll
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$buildPy = Join-Path $repoRoot 'scripts/build_index.py'

if (-not $SkipInstall) {
    Write-Host "Installing Python dependencies..." -ForegroundColor Green
    python -m pip install -q -r (Join-Path $repoRoot 'requirements.txt')
}

Write-Host "Building datasource + index + skillset + indexer..." -ForegroundColor Green
python $buildPy build

if (-not $NoPoll) {
    Write-Host "Polling indexer status (this can take several minutes)..." -ForegroundColor Green
    python $buildPy status
}
else {
    Write-Host "Indexer started. Poll with: python scripts/build_index.py status" -ForegroundColor Yellow
}
