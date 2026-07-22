# SharePoint Multimodal ACL Search

Turnkey deployment for a **multimodal, ACL-trimmed knowledge index** over a SharePoint document
library on **Azure AI Search**. It indexes text *and* images while preserving each document's
**Entra ACLs**, so queries only return what the calling user is allowed to see.

## What it builds

A custom-indexer pipeline (`*-nb7-*` objects) that combines:

| Skill | Purpose | Output |
|---|---|---|
| `ContentUnderstandingSkill` | Semantic chunking + page metadata + **image extraction** + **inline image verbalization** | `content`, `normalized_images` |
| `AzureOpenAIEmbeddingSkill` | Text embedding | `contentVector` (3072-dim) |
| `Vision.VectorizeSkill` | Azure AI Vision multimodal image embedding | `imageVector` (1024-dim) |

Two index-projection selectors emit **`kind="text"`** rows (chunk `content` + `contentVector`,
with figures verbalized inline as `![alt](figures/… "description")`) and **`kind="image"`** rows
(base64 `imageData` + `imageVector`). Both carry the SharePoint document metadata and the
`UserIds` / `GroupIds` ACL collections. The index sets `permissionFilterOption: enabled`, so every
query is trimmed to the caller's identity.

> **ACL-safe by design.** Image bytes are inlined as base64 `imageData` (no knowledge store) and
> figures are verbalized by Content Understanding's built-in model — both are compatible with ACL
> permission extraction, unlike the portal multimodal-RAG wizard's knowledge store + standalone
> Chat Completion skill.

## Index schema

```
id, parent_id, parent_id_img, kind, content, contentVector(3072), imageVector(1024),
  imageData, page, pageTo, sourceFile, metadata_spo_item_id, webUrl,
metadata_spo_item_path, lastModified, UserIds, GroupIds
```

## Prerequisites (tools)

- Azure CLI (`az login`), PowerShell 7+, Python 3.9+.
- A SharePoint Online site whose library you want to index.
- Region with Azure AI Vision **multimodal embeddings** availability (e.g. `eastus2`).

## Permissions

There are three distinct permission concerns: (1) what the **person running the deploy** must
have, (2) what the deploy **assigns** to the app + managed identities, and (3) what an
**end user querying** the index needs.

### 1. Permissions the deploying identity needs

The account you run `deploy.ps1` (or the manual steps) with must hold **both** an Azure RBAC role
and Microsoft Entra directory roles, because the deploy touches ARM, Entra, and SharePoint:

| Plane | Action performed | Required role on the deployer |
|---|---|---|
| Azure RBAC (ARM) | Create RG, Search, Foundry, model deployments | **Contributor** (or Owner) on the subscription / resource group |
| Azure RBAC (ARM) | `az role assignment create` (grants below) | **Owner** or **User Access Administrator** on the RG |
| Microsoft Entra | `az ad app create` / `az ad sp create` | **Application Administrator** or **Cloud Application Administrator** (or `Application.ReadWrite.All`) |
| Microsoft Entra | `az ad app permission admin-consent` (Graph + SharePoint app roles) + the temporary `Sites.FullControl.All` bootstrap | **Privileged Role Administrator** or **Global Administrator** (tenant-wide admin consent) |

> The single simplest setup is a deployer who is **Owner** on the resource group **and**
> **Global Administrator** (or Privileged Role Administrator) in the tenant. If admin-consent
> rights are held by a different person, split the run: an app admin runs everything except
> step 4/6, and the consent admin runs `az ad app permission admin-consent --id <appId>` and the
> per-site grant.

Verify before deploying:

```powershell
az account show --query "user.name"                 # who you are on ARM
az role assignment list --assignee (az ad signed-in-user show --query id -o tsv) `
    --scope /subscriptions/<sub>/resourceGroups/<rg> -o table
az rest --method get --url "https://graph.microsoft.com/v1.0/me/memberOf?$select=displayName" `
    --query "value[].displayName"                   # your Entra directory roles
```

### 2. Permissions the deploy assigns

`scripts/setup-app-registration.ps1` (invoked by `deploy.ps1`) creates the app registration and
assigns everything below. Nothing here needs to be assigned by hand.

**On the SharePoint app registration — all are `Application` (app-only) permissions; there are
NO `Delegated` permissions.** The indexer runs headless (app-only client-credentials), so every
permission below is an application role that requires **tenant admin consent**:

| API | Permission | Type | Why |
|---|---|---|---|
| Microsoft Graph | `Files.Read.All` | Application | Read document content for indexing |
| Microsoft Graph | `Sites.Selected` | Application | Least-privilege site access (only granted sites) |
| SharePoint (Office 365) | `Sites.Selected` | Application | Honor native site groups at query time |
| SharePoint (Office 365) | `User.Read.All` | Application | Resolve user/group ACLs |
| Microsoft Graph | `Sites.FullControl.All` | Application | **Temporary** — added only to write the per-site `read` grant, then **removed** (least privilege) |

Plus, on the app: **admin consent** for the above, a **client secret** (1-year), a **federated
credential** trusting the search managed identity, and a scoped **`read` grant** on each
`-SiteUrls` site (this is what `Sites.Selected` limits access to).

> **Verified end-to-end** (dedicated test app `spmm-sharepoint-acl-test`): after the script runs,
> the app's consented `appRoleAssignments` are exactly the four `Application` roles above with
> **zero `oauth2PermissionGrants`** (no delegated), `Sites.FullControl.All` is gone, and the app
> successfully indexes the granted site with ACL trimming intact.

#### Why `Sites.FullControl.All` — and how to avoid it

The app only ever needs `Sites.Selected` at runtime. But granting an app `Sites.Selected` `read`
on a specific site is itself a **write** to that site's permissions
(`POST https://graph.microsoft.com/v1.0/sites/{id}/permissions`), and Microsoft Graph requires
**`Sites.FullControl.All` (Application)** for that single call — `Sites.Selected` cannot grant
itself, and a plain `az login` token does not carry that scope. There is no lesser Graph
permission that can write a site grant.

`setup-app-registration.ps1` therefore **bootstraps and immediately reverts**: it adds
`Sites.FullControl.All` to the app, admin-consents, uses the app's *own* app-only token to write
the one `read` grant, then **removes `Sites.FullControl.All`** (`Grant-AppSiteAccess`). The app's
steady-state permission set is only the four `Application` roles above — the elevated permission
never persists.

**Prefer the app to never hold `Sites.FullControl.All`, even briefly?** Skip the bootstrap and have
a SharePoint/Graph admin perform the per-site grant manually, once, with a privileged identity:

```powershell
# PnP PowerShell — admin grants the app 'read' on the site; the app never gets FullControl
Grant-PnPAzureADAppSitePermission -AppId <appId> -DisplayName spmm-sharepoint-acl `
    -Site https://<tenant>.sharepoint.com/sites/<site> -Permissions Read
```

Then delete the `Grant-AppSiteAccess` bootstrap block (and its call at step 6) from
`setup-app-registration.ps1`. The trade-off is an extra manual admin step per site instead of a
fully automated, self-reverting grant.

**Azure RBAC role assignments:**

| Assignee | Role | Scope | Why |
|---|---|---|---|
| Search service system-assigned MI | **Cognitive Services User** | Foundry (AI Services) account | Keyless calls to Content Understanding, verbalization chat, Azure AI Vision, text embeddings |
| You (`-DeveloperPrincipalId`) | **Search Service Contributor** | Search service | Create datasource / index / skillset / indexer |
| You (`-DeveloperPrincipalId`) | **Search Index Data Contributor** | Search service | Upload/query documents, run ACL-trimmed queries |

### 3. How to assign them (manually, if not using `deploy.ps1`)

The scripts do this for you, but the equivalent manual commands are:

```powershell
# --- Azure RBAC ---
# Search MI -> Cognitive Services User on the Foundry account
az role assignment create --assignee-object-id <searchIdentityPrincipalId> `
    --assignee-principal-type ServicePrincipal `
    --role "Cognitive Services User" --scope <foundryResourceId>

# You -> search data-plane roles
$me = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee-object-id $me --assignee-principal-type User `
    --role "Search Service Contributor"    --scope <searchServiceResourceId>
az role assignment create --assignee-object-id $me --assignee-principal-type User `
    --role "Search Index Data Contributor" --scope <searchServiceResourceId>

# --- Entra app permissions (Graph example) ---
az ad app permission add --id <appId> --api 00000003-0000-0000-c000-000000000000 `
    --api-permissions <Files.Read.All-roleId>=Role <Sites.Selected-roleId>=Role
az ad app permission admin-consent --id <appId>
```

`<foundryResourceId>`, `<searchServiceResourceId>`, and `<searchIdentityPrincipalId>` are all
Bicep outputs (`az deployment group show -g <rg> -n main --query properties.outputs`).

### End-user query permissions

At query time, results are ACL-trimmed: a user only sees a document if their Entra `oid` (or a
group they belong to) is in that document's SharePoint permissions. **Two tokens** are involved on
the query call:

- `Authorization: Bearer <search token>` — authenticates the caller to the search data plane. The
  **calling identity** (the user directly, or a middle-tier app querying on their behalf) needs the
  **`Search Index Data Reader`** Azure RBAC role on the search service.
- `x-ms-query-source-authorization: Bearer <user token>` — the end user's token, used **only** for
  ACL trimming. The end user needs no Azure RBAC role; their access is governed entirely by
  SharePoint permissions, which Azure AI Search enforces.

Without the `x-ms-query-source-authorization` header the query returns only documents shared
broadly in SharePoint (verified: 10 public rows vs 86 with the header).

## Deploy (one command)

```powershell
./deploy.ps1 -ResourceGroup rg-spmm -Location eastus2 `
             -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>"
```

`deploy.ps1` runs, in order:

1. **Bicep** (`infra/main.bicep`) — Azure AI Search (system MI, semantic ranker) + Foundry
   (AI Services) account, project, and model deployments (`text-embedding-3-large`, `gpt-4.1-mini`).
2. **App registration** (`scripts/setup-app-registration.ps1`) — creates the SharePoint app,
   Graph + SharePoint permissions, admin consent, client secret, federated credential, per-site
   `read` grant, and RBAC (search MI → *Cognitive Services User*; you → search data-plane roles).
3. Writes **`.env`** from the deployment outputs + app registration.
4. `pip install -r requirements.txt`.
5. **Index build** (`scripts/build_index.py build`) — datasource, index, skillset, indexer (auto-runs).
6. Polls indexer status.

## Manual / step-by-step

```powershell
# 1. Infra
az group create -n rg-spmm -l eastus2
az deployment group create -g rg-spmm -f infra/main.bicep -p infra/main.bicepparam

# 2. App registration + RBAC (fills SHAREPOINT_CONNECTION_STRING into .env)
./scripts/setup-app-registration.ps1 `
    -SearchIdentityPrincipalId <fromOutput> `
    -FoundryResourceId <fromOutput> `
    -SearchServiceResourceId <fromOutput> `
    -DeveloperPrincipalId (az ad signed-in-user show --query id -o tsv) `
    -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>" `
    -EnvPath ./.env

# 3. Build the index
python scripts/build_index.py build
python scripts/build_index.py status    # poll until success
python scripts/build_index.py docs       # sample text + image rows
```

> Prefer a notebook? **`notebooks/01_setup_index.ipynb`** performs the exact same step 3
> (datasource → index → skillset → indexer → run → verify) as clean, `.env`-driven REST
> calls with an explanation of every payload — a readable alternative to `build_index.py`.

## Querying with ACL trimming

Every query must forward the caller's identity in the **`x-ms-query-source-authorization`** header,
or Search returns only public (`["all"]`) documents:

```python
headers = {
    "Authorization": f"Bearer {token}",              # authenticates the caller
    "x-ms-query-source-authorization": user_token,   # identity used for ACL trimming
}
```

See **`notebooks/demo_retrieval_and_images.ipynb`** for a full walkthrough: full-text retrieval,
semantic retrieval, **text→image vector search**, and **rendering the extracted images inline**.

## Layout

```
infra/
  main.bicep, main.bicepparam
  modules/search.bicep, modules/foundry.bicep
scripts/
  setup-app-registration.ps1   # SharePoint app + permissions + RBAC
  build_index.py               # datasource / index / skillset / indexer + query
deploy.ps1                     # orchestrator
notebooks/
  01_setup_index.ipynb           # build the 4 search resources via REST (.env-driven)
  demo_retrieval_and_images.ipynb
```
