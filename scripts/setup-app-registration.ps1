#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the SharePoint app registration + permissions and wires all RBAC needed by the
    multimodal, ACL-trimmed index, then prints (and optionally writes) the .env values.

    Steps:
      1. Create (or reuse) a dedicated Entra app registration.
      2. Add Microsoft Graph application permissions (Files.Read.All + Sites.Selected).
      3. Add SharePoint (Office 365) application permissions (Sites.Selected + User.Read.All) so
         native site groups resolve at query time.
      4. Grant admin consent.
      5. Create a client secret (client-secret path = Entra user/group ACL trimming).
      6. Create a federated credential trusting the search managed identity (enables the optional
         native SharePoint site-group path).
      7. Grant the app 'read' on each -SiteUrls site (required for Sites.Selected).
      8. Grant the search managed identity "Cognitive Services User" on the Foundry resource
         (Content Understanding + verbalization chat + Azure AI Vision + text embeddings).

    This script does NOT grant the developer their search data-plane roles (Search Service
    Contributor + Search Index Data Contributor) — that is handled by the orchestrator deploy.ps1,
    or granted separately by an Owner/User Access Administrator (see README "How to deploy").

    Run as an Entra admin (able to grant admin consent) who is also Owner / User Access
    Administrator on the Foundry (Cognitive Services) resource.

    Microsoft Learn:
      - SharePoint indexer:  https://learn.microsoft.com/azure/search/search-how-to-index-sharepoint-online
      - ACL trimming:        https://learn.microsoft.com/azure/search/search-query-access-control-rbac-enforcement
      - Content Understanding skill: https://learn.microsoft.com/azure/search/cognitive-search-skill-content-understanding

.EXAMPLE
    ./setup-app-registration.ps1 `
        -SearchIdentityPrincipalId "<searchIdentityPrincipalId from bicep output>" `
        -FoundryResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry>" `
        -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>" `
        -EnvPath ../.env
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SearchIdentityPrincipalId,
    [Parameter(Mandatory)] [Alias('OpenAIResourceId')] [string] $FoundryResourceId,
    [Parameter(Mandatory)] [string[]] $SiteUrls,
    [string] $AppDisplayName = 'spmm-sharepoint-acl',
    [string] $TenantId,
    # When set, appends the SharePoint connection values to this .env file.
    [string] $EnvPath
)

$ErrorActionPreference = 'Stop'

$GraphAppId      = '00000003-0000-0000-c000-000000000000'  # Microsoft Graph
$SharePointAppId = '00000003-0000-0ff1-ce00-000000000000'  # Office 365 SharePoint Online

$sitesRole       = 'Sites.Selected'
$GraphRoles      = @('Files.Read.All', $sitesRole)
$SharePointRoles = @($sitesRole, 'User.Read.All')

if (-not $TenantId) { $TenantId = az account show --query tenantId -o tsv }

function Resolve-AppRoleIds {
    param([string] $ResourceAppId, [string[]] $RoleValues)
    $sp = az ad sp show --id $ResourceAppId 2>$null | ConvertFrom-Json
    if (-not $sp) { throw "Service principal for resource $ResourceAppId not found in this tenant." }
    $ids = @()
    foreach ($value in $RoleValues) {
        $role = $sp.appRoles | Where-Object { $_.value -eq $value -and $_.allowedMemberTypes -contains 'Application' }
        if (-not $role) { throw "App role '$value' not found on resource $ResourceAppId." }
        $ids += $role.id
    }
    return $ids
}

function Grant-Rbac {
    param([string] $RoleName, [string] $PrincipalId, [string] $Scope, [string] $PrincipalTypeArg = 'ServicePrincipal')
    $existing = az role assignment list --assignee $PrincipalId --role $RoleName --scope $Scope --query "[0]" | ConvertFrom-Json
    if ($existing) { Write-Host "'$RoleName' already assigned on:`n  $Scope" -ForegroundColor Yellow; return }
    Write-Host "Assigning '$RoleName' to $PrincipalId on:`n  $Scope" -ForegroundColor Green
    az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $PrincipalTypeArg --role $RoleName --scope $Scope 1>$null
}

function Grant-AppSiteAccess {
    param([string] $AppClientId, [string] $AppName, [string] $Url, [string] $AppSecret, [string] $Tenant)
    # Writing /sites/{id}/permissions needs Sites.FullControl.All, which a plain az login token does
    # not carry. Bootstrap: give the app Graph Sites.FullControl.All, consent, use its OWN app-only
    # token to write the scoped Sites.Selected 'read' grant, then REMOVE FullControl (least privilege).
    $Graph = '00000003-0000-0000-c000-000000000000'
    $graphSp = az ad sp show --id $Graph | ConvertFrom-Json
    $fcRole = ($graphSp.appRoles | Where-Object { $_.value -eq 'Sites.FullControl.All' -and $_.allowedMemberTypes -contains 'Application' }).id

    Write-Host "Temporarily granting Graph Sites.FullControl.All to bootstrap the site grant..." -ForegroundColor DarkYellow
    az ad app permission add --id $AppClientId --api $Graph --api-permissions "$fcRole=Role" 1>$null 2>$null
    Start-Sleep 5
    az ad app permission admin-consent --id $AppClientId 1>$null 2>$null
    Start-Sleep 20

    $body = @{ client_id = $AppClientId; scope = 'https://graph.microsoft.com/.default'; client_secret = $AppSecret; grant_type = 'client_credentials' }
    $token = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token" -Body $body).access_token

    $uri = [Uri] $Url
    $lookup = "https://graph.microsoft.com/v1.0/sites/$($uri.Host):$($uri.AbsolutePath.TrimEnd('/'))"
    $site = Invoke-RestMethod -Method Get -Uri $lookup -Headers @{ Authorization = "Bearer $token" }
    if (-not $site.id) { throw "Could not resolve site id for $Url." }

    $grant = @{ roles = @('read'); grantedToIdentities = @(@{ application = @{ id = $AppClientId; displayName = $AppName } }) } | ConvertTo-Json -Depth 6
    Write-Host "Granting 'read' to '$AppName' on $Url ..." -ForegroundColor Green
    try {
        Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/permissions" -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $grant 1>$null
    }
    catch {
        if ($_.ErrorDetails.Message -notmatch 'already') { throw }
        Write-Host "  (site grant already exists)" -ForegroundColor Yellow
    }

    Write-Host "Removing temporary Sites.FullControl.All (restoring least privilege)..." -ForegroundColor DarkYellow
    $spId = az ad sp show --id $AppClientId --query id -o tsv
    $asn = (az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" | ConvertFrom-Json).value | Where-Object { $_.appRoleId -eq $fcRole }
    if ($asn) { az rest --method delete --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments/$($asn.id)" 2>$null | Out-Null }
    az ad app permission delete --id $AppClientId --api $Graph --api-permissions $fcRole 2>$null | Out-Null
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " SharePoint multimodal ACL search - app registration + RBAC" -ForegroundColor Cyan
Write-Host " Tenant: $TenantId" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# --- 1. Create or reuse the app registration --------------------------------
$existing = az ad app list --display-name $AppDisplayName --query "[0]" | ConvertFrom-Json
if ($existing) {
    Write-Host "Reusing existing app registration '$AppDisplayName' ($($existing.appId))." -ForegroundColor Yellow
    $appId = $existing.appId; $appObjectId = $existing.id
}
else {
    Write-Host "Creating app registration '$AppDisplayName'..." -ForegroundColor Green
    $app = az ad app create --display-name $AppDisplayName --sign-in-audience AzureADMyOrg | ConvertFrom-Json
    $appId = $app.appId; $appObjectId = $app.id
    az ad sp create --id $appId 1>$null
}

# --- 2. Microsoft Graph application permissions -----------------------------
Write-Host "Adding Microsoft Graph application permissions ($($GraphRoles -join ', '))..." -ForegroundColor Green
foreach ($id in (Resolve-AppRoleIds -ResourceAppId $GraphAppId -RoleValues $GraphRoles)) {
    az ad app permission add --id $appId --api $GraphAppId --api-permissions "$id=Role" 1>$null
}

# --- 3. SharePoint application permissions ----------------------------------
Write-Host "Adding SharePoint application permissions ($($SharePointRoles -join ', '))..." -ForegroundColor Green
foreach ($id in (Resolve-AppRoleIds -ResourceAppId $SharePointAppId -RoleValues $SharePointRoles)) {
    az ad app permission add --id $appId --api $SharePointAppId --api-permissions "$id=Role" 1>$null
}

# --- 4. Admin consent -------------------------------------------------------
Write-Host "Granting admin consent (requires a privileged admin)..." -ForegroundColor Green
az ad app permission admin-consent --id $appId

# --- 4b. Client secret ------------------------------------------------------
Write-Host "Creating a client secret..." -ForegroundColor Green
$clientSecret = az ad app credential reset --id $appId --display-name 'search-indexer' --years 1 --query password -o tsv

# --- 5. Federated credential trusting the search managed identity -----------
$ficName = 'search-managed-identity'
$ficBody = @{ name = $ficName; issuer = "https://login.microsoftonline.com/$TenantId/v2.0"; subject = $SearchIdentityPrincipalId; audiences = @('api://AzureADTokenExchange') } | ConvertTo-Json -Compress
$existingFic = az ad app federated-credential list --id $appObjectId --query "[?name=='$ficName'] | [0]" | ConvertFrom-Json
if ($existingFic) { Write-Host "Federated credential '$ficName' already exists." -ForegroundColor Yellow }
else {
    Write-Host "Creating federated credential '$ficName'..." -ForegroundColor Green
    $tmpFic = New-TemporaryFile
    Set-Content -Path $tmpFic -Value $ficBody -Encoding utf8
    try { az ad app federated-credential create --id $appObjectId --parameters "@$tmpFic" | Out-Null }
    finally { Remove-Item $tmpFic -ErrorAction SilentlyContinue }
}

# --- 6. Per-site 'read' grants ----------------------------------------------
foreach ($u in $SiteUrls) { Grant-AppSiteAccess -AppClientId $appId -AppName $AppDisplayName -Url $u -AppSecret $clientSecret -Tenant $TenantId }

# --- 7. Search managed identity -> Foundry (Cognitive Services) -------------
Grant-Rbac -RoleName 'Cognitive Services User' -PrincipalId $SearchIdentityPrincipalId -Scope $FoundryResourceId

# --- Output -----------------------------------------------------------------
$connString = "SharePointOnlineEndpoint=$($SiteUrls[0]);ApplicationId=$appId;ApplicationSecret=$clientSecret;TenantId=$TenantId"

Write-Host "`n================ SharePoint connection (.env) ================" -ForegroundColor Cyan
Write-Host "  SP_APP_CLIENT_ID=$appId"
Write-Host "  SP_TENANT_ID=$TenantId"
Write-Host "  SHAREPOINT_CONNECTION_STRING=$connString"
Write-Host "==============================================================" -ForegroundColor Cyan

if ($EnvPath) {
    Write-Host "Appending SharePoint connection values to $EnvPath ..." -ForegroundColor Green
    Add-Content -Path $EnvPath -Value "`nSP_APP_CLIENT_ID=$appId"
    Add-Content -Path $EnvPath -Value "SP_TENANT_ID=$TenantId"
    Add-Content -Path $EnvPath -Value "SHAREPOINT_CONNECTION_STRING=$connString"
}

Write-Host "`nApp registration + RBAC complete. Store the client secret securely - it is shown only once." -ForegroundColor Green
