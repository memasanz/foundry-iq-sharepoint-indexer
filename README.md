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

#### Client secret vs. federated credential — what each is for

The script provisions **two** credentials on the app. They serve different jobs:

**Client secret — required (this is the auth path the pipeline actually uses).**
The SharePoint indexer runs headless (no signed-in user), so it authenticates to SharePoint /
Microsoft Graph **app-only** using the app's client ID + secret. The secret is passed to the
indexer inside `SHAREPOINT_CONNECTION_STRING` as `ApplicationSecret=...`:

```
SharePointOnlineEndpoint=https://<tenant>.sharepoint.com/sites/<site>;ApplicationId=<appId>;ApplicationSecret=<clientSecret>;TenantId=<tenantId>
```

That app-only token is what lets the indexer read document content **and** read each item's
Entra user/group object IDs (via `User.Read.All`) into the `UserIds` / `GroupIds` ACL fields that
drive query-time trimming. Without it the indexer cannot connect. The secret is issued for **1
year** — rotate it (`az ad app credential reset --id <appId>`) and update the connection string
before it expires, or indexing stops.

**Federated credential — optional (secretless / native SharePoint site-group path).**
This is a workload-identity-federation credential that **trusts the search service's managed
identity**:

| Field | Value |
|---|---|
| `issuer` | `https://login.microsoftonline.com/<tenantId>/v2.0` |
| `subject` | the search service managed identity principal ID |
| `audience` | `api://AzureADTokenExchange` |

It lets the **search managed identity exchange its own MI token for an app-only token of this app
with no stored secret** — the basis for the secretless connection option and for resolving
**native SharePoint site groups** (not just Entra objects) at query time. The shipped connection
string above uses the client secret, so you do **not** need the federated credential for the Entra
user/group ACL trimming this repo demonstrates; it is created so the secretless / native-group path
is available if you choose it. If you never use that path you can safely delete it
(`az ad app federated-credential delete --id <appObjectId> --federated-credential-id <name>`).

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

## Azure resources deployed

`infra/main.bicep` (via `deploy.ps1`) provisions everything below into a single resource group.
Names derive from `-BaseName` (default `spmm`) plus a hash of the resource-group ID, so they are
globally unique. Both services use a **system-assigned managed identity** and **Entra-only
(keyless) data-plane auth** (`disableLocalAuth: true`).

| Resource | Type / kind | SKU | Purpose |
|---|---|---|---|
| `spmm-search-<hash>` | `Microsoft.Search/searchServices` | `basic` (configurable), **semantic ranker = standard** | Hosts the datasource, index, skillset, and indexer; runs ACL-trimmed multimodal queries. Its MI calls Foundry keyless. |
| `spmm-foundry-<hash>` | `Microsoft.CognitiveServices/accounts`, kind **`AIServices`** | `S0` | One account serving **Azure OpenAI** (embeddings + verbalization chat), **Content Understanding**, and **Azure AI Vision** multimodal embeddings. |
| `spmm-proj` | `Microsoft.CognitiveServices/accounts/projects` | — | Foundry project under the account (`allowProjectManagement`). |
| `text-embedding-3-large` | account model deployment | `Standard`, cap 50 | Text embeddings → `contentVector` (3072-dim). |
| `gpt-4.1-mini` | account model deployment | `GlobalStandard`, cap 50 | Content Understanding **image verbalization** (inline figure descriptions). |

> **Not ARM resources.** The SharePoint **app registration** (Entra) is created by
> `setup-app-registration.ps1`, and the **datasource / index / skillset / indexer** are Azure AI
> Search *data-plane* objects created by `build_index.py` — none of these appear in the resource
> group. The Foundry account also provides Content Understanding and Vision multimodal embeddings
> with **no extra model deployment**.

**Region:** default `eastus2`. Azure AI Vision multimodal-embedding availability varies by region —
pick a region that supports it (see prerequisites). Change SKUs/region/models via `-BaseName`,
`-Location`, `infra/main.bicepparam`, or the `deployments` param in `infra/main.bicep`.

**Deploy just the infrastructure** (no app registration / index):

```powershell
az group create -n rg-spmm -l eastus2
az deployment group create -g rg-spmm -f infra/main.bicep -p infra/main.bicepparam
# resource IDs + endpoints needed by the setup script:
az deployment group show -g rg-spmm -n main --query properties.outputs
```

Or run `deploy.ps1 -SkipAppRegistration -SkipIndex` to stop after provisioning. The full
end-to-end flow is below.

## Deploy (one command)

```powershell
./deploy.ps1 -ResourceGroup rg-spmm -Location eastus `
             -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>"
```

> **⚠️ Region matters — use a Vision-capable region (e.g. `eastus`).** The skillset includes the
> Azure AI Vision multimodal-embeddings skill (`Microsoft.Skills.Vision.VectorizeSkill`), which is
> **not available in `eastus2`** — a build there fails at skillset creation with
> *"…which is not supported in this region."* Pass `-Location eastus` (the `deploy.ps1` default is
> `eastus2`, so set it explicitly). Verify multimodal-embedding availability for your region in the
> [skill reference](https://learn.microsoft.com/azure/search/cognitive-search-skill-vision-vectorize#supported-regions).
> If you must deploy to `eastus2`, drop the Vision skill (see *Deploy without the Vision skill* below).

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
# 1. Infra  (use a Vision-capable region — eastus, NOT eastus2)
az group create -n rg-spmm -l eastus
az deployment group create -g rg-spmm -f infra/main.bicep -p infra/main.bicepparam -p location=eastus

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

## Split deploy: developer vs. admin (separation of duties)

`deploy.ps1` runs infra **and** the privileged app-registration/RBAC/consent step in one shot, so a
single operator would need to be both **Contributor** on the resource group **and** a
**Privileged-Role/Application admin + Owner/User Access Administrator**. To keep those duties
separate, use the built-in `-SkipInfra` / `-SkipAppRegistration` / `-SkipIndex` switches to run the
flow in three phases — no code changes required.

**Super admin (holds every role) — one command, no phases.** If a single operator is
**Contributor** on the RG **and** an **App/Privileged-Role admin** **and** **Owner/User Access
Administrator**, they can do everything in one shot (this is the [Deploy (one command)](#deploy-one-command)
path — it runs infra → app registration + all RBAC + consent → build):

```powershell
./deploy.ps1 -ResourceGroup rg-spmm -Location eastus `
             -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>"
```

Otherwise, hand the work off in three phases:

| Phase | Who | Rights needed | Actions |
|---|---|---|---|
| **1. Infra** | Developer | Contributor on the RG | `az deployment group create` (Bicep: search + Foundry + models) → outputs MI principalId + resource IDs |
| **2. Admin** | Admin | App/Privileged-Role admin **+** Owner/UAA | App registration, Graph/SharePoint perms, **admin consent**, client secret, federated cred, per-site `read` grant, **all RBAC** (search MI → *Cognitive Services User*; developer → the 2 Search roles) → returns `SHAREPOINT_CONNECTION_STRING` |
| **3. Build** | Developer | The 2 Search roles the admin granted | `python scripts/build_index.py build` / `status` |

**Phase 1 — Developer (Contributor on the RG): provision infra only.**

```powershell
./deploy.ps1 -ResourceGroup rg-spmm -Location eastus `
             -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>" `
             -SkipAppRegistration -SkipIndex
```

This deploys the Bicep (search + Foundry + models) and writes `.env` with the resource endpoints —
but does **no** Entra work, **no** RBAC, and **no** index build. Then collect the values the admin
needs (from the Bicep outputs) plus your own principal id:

```powershell
az deployment group show -g rg-spmm -n main --query properties.outputs   # searchIdentityPrincipalId, foundryResourceId, searchServiceResourceId
az ad signed-in-user show --query id -o tsv                              # your object id -> give to the admin
```

**Phase 2 — Admin (App/Privileged-Role admin + Owner/UAA): app registration + all grants.**

The admin runs `setup-app-registration.ps1` directly with the Phase 1 outputs. This creates the app,
Graph/SharePoint permissions, **admin consent**, client secret, federated credential, per-site
`read` grant, and every RBAC assignment (search MI → *Cognitive Services User* on the Foundry; the
developer → *Search Service Contributor* + *Search Index Data Contributor* on the search service):

```powershell
./scripts/setup-app-registration.ps1 `
    -SearchIdentityPrincipalId <searchIdentityPrincipalId> `
    -FoundryResourceId <foundryResourceId> `
    -SearchServiceResourceId <searchServiceResourceId> `
    -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>" `
    -DeveloperPrincipalId <developer object id> `
    -EnvPath ./.env
```

It prints (and, with `-EnvPath`, appends) `SHAREPOINT_CONNECTION_STRING`. Hand that value back to the
developer to place in their `.env` (the client secret is shown only once — share it securely).

**Phase 3 — Developer: build the index.**

```powershell
python scripts/build_index.py build
python scripts/build_index.py status    # poll until success
```

> ⚠️ For Phase 3, call `build_index.py` **directly** — do **not** re-run `deploy.ps1` (even with
> `-SkipInfra -SkipAppRegistration`). `deploy.ps1` rewrites `.env` from the infra outputs on every
> run and would overwrite the admin-supplied `SHAREPOINT_CONNECTION_STRING`.

## Deploy to an existing search service (reuse existing Search + Foundry)

If the Azure AI Search service and a Foundry (AI Services) account **already exist** — you only
want to build this index onto them — skip the Bicep step entirely. You just need a system-assigned
managed identity on the search service, three role assignments, a filled `.env`, and `build_index.py`.

The search service must be in a **Vision-capable region** (e.g. `eastus`), and the Foundry account
must have the `text-embedding-3-large` and `gpt-4.1-mini` model deployments (any Foundry with them
works — it does not have to be in the same region or resource group as the search service, because
billing uses a keyless connection).

```powershell
# Names of the pre-existing resources
$search      = "search-7zmdhqwh4d4ve"                # your existing Azure AI Search service
$searchRg    = "rg-lpa-dev-eastus"
$foundryId   = az cognitiveservices account show -n <foundry> -g <foundryRg> --query id -o tsv

# 1. Ensure the search service has a system-assigned managed identity
$searchMi = az search service update -n $search -g $searchRg `
    --identity-type SystemAssigned --query identity.principalId -o tsv

# 2. Grant that MI keyless access to the Foundry (Content Understanding, embeddings, Vision)
az role assignment create --assignee-object-id $searchMi --assignee-principal-type ServicePrincipal `
    --role "Cognitive Services User" --scope $foundryId

# 3. Grant yourself the data-plane roles to create the objects and run ACL-trimmed queries
$searchId = az search service show -n $search -g $searchRg --query id -o tsv
$me = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee-object-id $me --assignee-principal-type User `
    --role "Search Service Contributor"    --scope $searchId
az role assignment create --assignee-object-id $me --assignee-principal-type User `
    --role "Search Index Data Contributor" --scope $searchId

# 4. Fill .env (see .env.example): AZURE_SEARCH_ENDPOINT, AZURE_OPENAI_ENDPOINT,
#    AZURE_AI_SERVICES_ENDPOINT, model deployment names, and SHAREPOINT_CONNECTION_STRING.
#    (The SharePoint app registration from scripts/setup-app-registration.ps1 can be reused.)

# 5. Build and run the index
python scripts/build_index.py build
python scripts/build_index.py status    # poll until success
python scripts/build_index.py run       # re-run the indexer any time afterward
```

Role assignments can take a minute to propagate; if `build` returns 403, wait and retry.

## Deploy without the Vision skill (e.g. into `eastus2`)

The Vision multimodal-embeddings skill is unavailable in some regions (notably `eastus2`). To index
there, drop the Vision pieces — you keep text chunking, text embeddings, image **extraction** +
inline **verbalization**, base64 image rendering, and ACL trimming; you lose only text→image vector
similarity search. Remove from `scripts/build_index.py` (or a copy of it):

- the `imageVector` field, the `image-profile` vector profile, and the `vision-vectorizer` vectorizer
  (in `build_index`);
- the `image_embed` (`#Microsoft.Skills.Vision.VectorizeSkill`) skill (in `build_skillset`);
- the `imageVector` mapping from the image index-projection selector.

Because field removal isn't allowed on an existing index, delete the index first if it already
exists (`DELETE indexes/<name>`), then re-run `build`.

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
