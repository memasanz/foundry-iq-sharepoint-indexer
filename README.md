# SharePoint Multimodal ACL Search

Turnkey deployment for a **multimodal, ACL-trimmed knowledge index** over a SharePoint document
library on **Azure AI Search**. It indexes text *and* images while preserving each document's
**Entra ACLs**, so queries only return what the calling user is allowed to see.

## Contents

1. [What you're deploying](#what-youre-deploying) — the pipeline, index schema, ACL model, and Azure resources.
2. [Deploy at a glance](#deploy-at-a-glance) — the three scripts, in the order you run them.
3. [Requirements & service limits](#requirements--service-limits) — tools, the region constraint, and known service limits.
4. [Permissions](#permissions) — what the deployer needs, what the deploy assigns, and end-user query rights.
5. [How to deploy](#how-to-deploy) — one command, split developer/admin, existing service, or without Vision.
6. [Querying with ACL trimming](#querying-with-acl-trimming).
7. [Repo layout](#repo-layout).

---

## What you're deploying

### The pipeline

A custom-indexer pipeline (`*-nb7-*` objects) that combines three skills:

| Skill | Purpose | Output |
|---|---|---|
| `ContentUnderstandingSkill` | Semantic chunking + page metadata + **image extraction** + **inline image verbalization** | `content`, `normalized_images` |
| `AzureOpenAIEmbeddingSkill` | Text embedding | `contentVector` (3072-dim) |
| `Vision.VectorizeSkill` | Azure AI Vision multimodal image embedding | `imageVector` (1024-dim) |

### Index schema

An **Azure AI Search index** is the searchable store this pipeline populates — think of it as a
table whose rows ("documents") are the chunked pieces of your SharePoint files and whose columns
("fields") hold the searchable text, the vector embeddings, the source metadata, and the ACL lists.
Each field is typed and independently configured for what you can do with it — full-text
*searchable*, *filterable*, *sortable*, *facetable*, *retrievable* (returned in results), or a
vector field used for similarity search. Queries run against this index, and Search trims the
results to the caller using the two permission fields.

One source file becomes **many** index rows: one `kind="text"` row per text chunk and one
`kind="image"` row per extracted image, all linked back to the same document.

| Field | Type | Description |
|---|---|---|
| `id` | `Edm.String` (key) | Unique document key — the primary identifier for each row. |
| `parent_id` | `Edm.String` | ID of the source document a **text** chunk was projected from (groups text rows by file). |
| `parent_id_img` | `Edm.String` | ID of the source document an **image** row was projected from (groups image rows by file). |
| `kind` | `Edm.String` | Row type: **`text`** (a text chunk) or **`image`** (an extracted image). Filterable/facetable. |
| `content` | `Edm.String` | The chunk text (for `text` rows), with figures verbalized inline as `![alt](figures/… "description")`. Full-text searchable. |
| `contentVector` | `Collection(Edm.Single)` (3072) | Text embedding of `content` (`text-embedding-3-large`) for semantic/vector search. Not retrievable. |
| `imageVector` | `Collection(Edm.Single)` (1024) | Azure AI Vision multimodal embedding of an extracted image — enables text→image vector search. Not retrievable. |
| `imageData` | `Edm.String` | Base64-encoded bytes of the extracted image (for `image` rows), so images render directly with no knowledge store. |
| `page` | `Edm.Int32` | Starting page number of the chunk/image in the source file. |
| `pageTo` | `Edm.Int32` | Ending page number of the chunk (a chunk may span pages). |
| `sourceFile` | `Edm.String` | Source file name (also the semantic-ranker title field). |
| `metadata_spo_item_id` | `Edm.String` | SharePoint item ID of the source document. |
| `webUrl` | `Edm.String` | SharePoint URL of the source document (link back to the original). |
| `metadata_spo_item_path` | `Edm.String` | SharePoint library path of the source document. |
| `lastModified` | `Edm.DateTimeOffset` | Last-modified timestamp from SharePoint. Filterable/sortable. |
| `UserIds` | `Collection(Edm.String)` | Entra **user** object IDs allowed to see the document — a `permissionFilter` field driving ACL trimming. Not retrievable. |
| `GroupIds` | `Collection(Edm.String)` | Entra **group** object IDs allowed to see the document — a `permissionFilter` field driving ACL trimming. Not retrievable. |

### ACL trimming model

The index sets `permissionFilterOption: enabled`, so **every query is trimmed to the caller's
identity**. The indexer resolves each document's SharePoint permissions into the `UserIds` /
`GroupIds` collections; at query time, a user sees a document only if their Entra `oid` (or a group
they belong to) is in those collections. See [Querying with ACL trimming](#querying-with-acl-trimming)
for the two-token query contract.

### Azure resources

`infra/main.bicep` provisions everything below into a single resource group. Names derive from
`-BaseName` (default `spmm`) plus a hash of the resource-group ID, so they are globally unique. Both
services use a **system-assigned managed identity** and **Entra-only (keyless) data-plane auth**
(`disableLocalAuth: true`).

| Resource | Type / kind | SKU | Purpose |
|---|---|---|---|
| `spmm-search-<hash>` | `Microsoft.Search/searchServices` | `basic` default (`-SearchSku`: basic / standard=S1 / standard2 / standard3), **semantic ranker = standard** | Hosts the datasource, index, skillset, and indexer; runs ACL-trimmed multimodal queries. Its MI calls Foundry keyless. |
| `spmm-foundry-<hash>` | `Microsoft.CognitiveServices/accounts`, kind **`AIServices`** | `S0` | One account serving **Azure OpenAI** (embeddings + verbalization chat), **Content Understanding**, and **Azure AI Vision** multimodal embeddings. |
| `spmm-proj` | `Microsoft.CognitiveServices/accounts/projects` | — | Foundry project under the account (`allowProjectManagement`). |
| `text-embedding-3-large` | account model deployment | `Standard`, cap 50 | Text embeddings → `contentVector` (3072-dim). |
| `gpt-4.1-mini` | account model deployment | `GlobalStandard`, cap 50 | Content Understanding **image verbalization** (inline figure descriptions). |

> **Not ARM resources.** The SharePoint **app registration** (Entra) is created by
> `setup-app-registration.ps1`, and the **datasource / index / skillset / indexer** are Azure AI
> Search *data-plane* objects created by `build_index.py` — none of these appear in the resource
> group. The Foundry account also provides Content Understanding and Vision multimodal embeddings
> with **no extra model deployment**.

---

## Deploy at a glance

Now that you know *what* gets built, here's *how* — deployment is four scripts run **in order**.
`deploy.ps1` runs all four back-to-back; you can also run them one at a time (e.g. to
[split developer vs. admin duties](#option-b--split-developer-vs-admin)).

```
                   deploy.ps1  (orchestrator — runs the four in order)
                        │
  ┌─────────────────┬───┴────────────────┬────────────────────┐
  ▼                 ▼                     ▼                     ▼
1. deploy-infra.ps1  2. setup-app-        3. grant-developer-   4. build-index.ps1
                        registration.ps1     roles.ps1
```

**Step 1 — `scripts/deploy-infra.ps1`** *(run by a developer)*
Deploys the Bicep infrastructure — the Azure AI Search service and the Foundry (AI Services) account,
project, and model deployments — then writes the non-secret settings to `.env`.
**Requires:** **Contributor** (or Owner) on the target subscription / resource group — enough to
create the RG, Search, Foundry, and model deployments. No Entra or role-assignment rights needed.

```powershell
./scripts/deploy-infra.ps1 -ResourceGroup rg-spmm -Location eastus -BaseName spmm -SearchSku standard
```

`-BaseName` (default `spmm`) is the prefix for the resource names — e.g. `spmm-search-<hash>`,
`spmm-foundry-<hash>`, `spmm-proj`. Keep it lowercase letters/digits/dashes and short (the
search-service name must be ≤ 60 chars and can't start or end with a dash). See the script's help
for overriding a full name instead of just the prefix.

`-SearchSku` (default `basic`) picks the Azure AI Search tier: `basic`, `standard` (**= S1**, used
in the example above), `standard2` (S2), or `standard3` (S3). Use `standard`/S1 or higher for larger
libraries — `basic` caps out at ~15 GB storage and lower vector-index quota. Omit it to get `basic`.

**Step 2 — `scripts/setup-app-registration.ps1`** *(run by an admin)*
Creates the SharePoint app registration, grants and **admin-consents** the Graph/SharePoint app-only
permissions, issues the client secret + federated credential, and writes the per-site `read` grant.
Appends `SHAREPOINT_CONNECTION_STRING` to `.env`.
**Requires both:** **Application Administrator** / **Cloud Application Administrator** (to create the
app registration), and **Privileged Role Administrator** or **Global Administrator** (to grant
tenant-wide admin consent + the temporary `Sites.FullControl.All` bootstrap). No Azure RBAC here.

```powershell
./scripts/setup-app-registration.ps1 `
    -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>" `
    -AppDisplayName spmm-sharepoint-acl
```

The search-MI principal id is read from `.env` (written by Step 1); pass `-SearchIdentityPrincipalId`
to override. `-AppDisplayName` names the Entra app registration (default `spmm-sharepoint-acl`) — it
is **independent** of the infra `-BaseName`, so set it explicitly if you want it to match your prefix.

**Step 3 — `scripts/grant-dev-and-managed-identity.ps1`** *(run by an admin)*
Grants the two search data-plane roles the developer needs in Step 4 — **Search Service
Contributor** and **Search Index Data Contributor** (scoped to the search service) — plus the
**search managed identity** *Cognitive Services User* on the Foundry. Reads the resource ids from
`.env`; defaults the developer to the signed-in user if `-DeveloperPrincipalId` is omitted.
**Requires:** **Owner** or **User Access Administrator** on both the search service and the Foundry.

```powershell
./scripts/grant-dev-and-managed-identity.ps1 -DeveloperPrincipalId <developer object id>
```

**Step 4 — `scripts/build-index.ps1`** *(run by a developer)*
Installs the Python deps and runs `build_index.py build` — creating the datasource, index, skillset,
and indexer (the indexer runs automatically) — then polls until indexing completes.
**Requires:** the two search data-plane roles granted in Step 3. No ARM or Entra rights needed.

```powershell
./scripts/build-index.ps1
```

**Or run all four at once** (when one operator holds every role):

```powershell
./deploy.ps1 -ResourceGroup rg-spmm -Location eastus `
             -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>"
```

Before running, check [Requirements & service limits](#requirements--service-limits) and
[Permissions](#permissions) (what each step needs and assigns); see [How to deploy](#how-to-deploy)
for the full options (super-admin one-command, developer/admin split, reusing an existing search
service, or deploying without the Vision skill).

---

## Requirements & service limits

### Tools

- Azure CLI (`az login`), PowerShell 7+, Python 3.9+.
- A SharePoint Online site whose library you want to index.

### ⚠️ Region — must be Vision-capable (`eastus`, not `eastus2`)

The skillset includes the Azure AI Vision multimodal-embeddings skill
(`Microsoft.Skills.Vision.VectorizeSkill`), which is **not available in `eastus2`** — a build there
fails at skillset creation with *"…which is not supported in this region."* `deploy.ps1` and
`main.bicepparam` therefore default to **`eastus`**; override `-Location` only for another
Vision-capable region. Verify availability for your region in the
[skill reference](https://learn.microsoft.com/azure/search/cognitive-search-skill-vision-vectorize#supported-regions).
If you must deploy to `eastus2`, drop the Vision skill — see
[Option D](#option-d--without-the-vision-skill-eg-eastus2).

### Other service limits to know

| Limit | Detail |
|---|---|
| Content Understanding page count | The `standard` content-extraction path rejects files **>300 pages** (`InputPageCountExceeded`). Split very large PDFs, or the indexer flags those items as failed. |
| Semantic ranker | The index relies on the **standard** semantic ranker tier — provisioned by the Bicep on the search service. |
| Client secret lifetime | The SharePoint app's client secret is issued for **1 year**. Rotate it (`az ad app credential reset`) and update `SHAREPOINT_CONNECTION_STRING` before it expires, or indexing stops. |

---

## Permissions

There are three distinct permission concerns: (1) what the **person running the deploy** must have,
(2) what the deploy **assigns** to the app + managed identities, and (3) what an **end user
querying** the index needs.

### 1. Permissions the deploying identity needs

The account you run the deploy with must hold **both** an Azure RBAC role and Microsoft Entra
directory roles, because the deploy touches ARM, Entra, and SharePoint:

| Plane | Action performed | Required role on the deployer |
|---|---|---|
| Azure RBAC (ARM) | Create RG, Search, Foundry, model deployments | **Contributor** (or Owner) on the subscription / resource group |
| Azure RBAC (ARM) | `az role assignment create` (grants below) | **Owner** or **User Access Administrator** on the RG |
| Microsoft Entra | `az ad app create` / `az ad sp create` | **Application Administrator** or **Cloud Application Administrator** (or `Application.ReadWrite.All`) |
| Microsoft Entra | `az ad app permission admin-consent` (Graph + SharePoint app roles) + the temporary `Sites.FullControl.All` bootstrap | **Privileged Role Administrator** or **Global Administrator** (tenant-wide admin consent) |

> The simplest setup is a deployer who is **Owner** on the resource group **and** **Global
> Administrator** (or Privileged Role Administrator) in the tenant — the
> [one-command path](#option-a--one-command-super-admin). If those rights are split across people,
> use the [developer/admin split](#option-b--split-developer-vs-admin).

Verify before deploying:

```powershell
az account show --query "user.name"                 # who you are on ARM
az role assignment list --assignee (az ad signed-in-user show --query id -o tsv) `
    --scope /subscriptions/<sub>/resourceGroups/<rg> -o table
az rest --method get --url "https://graph.microsoft.com/v1.0/me/memberOf?$select=displayName" `
    --query "value[].displayName"                   # your Entra directory roles
```

### 2. Permissions the deploy assigns

`scripts/setup-app-registration.ps1` creates the app registration and assigns the app-related grants
(everything below except the Azure RBAC role assignments, which
`scripts/grant-dev-and-managed-identity.ps1` assigns). Nothing here needs to be assigned by hand.

**On the SharePoint app registration — all are `Application` (app-only) permissions; there are NO
`Delegated` permissions.** The indexer runs headless (app-only client-credentials), so every
permission below is an application role that requires **tenant admin consent**:

| API | Permission | Type | Why |
|---|---|---|---|
| Microsoft Graph | `Files.Read.All` | Application | Read document content for indexing |
| Microsoft Graph | `Sites.Selected` | Application | Least-privilege site access (only granted sites) |
| SharePoint (Office 365) | `Sites.Selected` | Application | Honor native site groups at query time |
| SharePoint (Office 365) | `User.Read.All` | Application | Resolve user/group ACLs |
| Microsoft Graph | `Sites.FullControl.All` | Application | **Temporary** — added only to write the per-site `read` grant, then **removed** (least privilege) |

Plus, on the app: **admin consent** for the above, a **client secret** (1-year), a **federated
credential** trusting the search managed identity, and a scoped **`read` grant** on each `-SiteUrls`
site (this is what `Sites.Selected` limits access to).

> **Verified end-to-end** (dedicated test app `spmm-sharepoint-acl-test`): after the script runs,
> the app's consented `appRoleAssignments` are exactly the four `Application` roles above with
> **zero `oauth2PermissionGrants`** (no delegated), `Sites.FullControl.All` is gone, and the app
> successfully indexes the granted site with ACL trimming intact.

**Azure RBAC role assignments:**

| Assignee | Role | Scope | Assigned by | Why |
|---|---|---|---|---|
| Search service system-assigned MI | **Cognitive Services User** | Foundry (AI Services) account | `grant-dev-and-managed-identity.ps1` | Keyless calls to Content Understanding, verbalization chat, Azure AI Vision, text embeddings |
| Developer (`-DeveloperPrincipalId`) | **Search Service Contributor** | Search service | `grant-dev-and-managed-identity.ps1` | Create datasource / index / skillset / indexer |
| Developer (`-DeveloperPrincipalId`) | **Search Index Data Contributor** | Search service | `grant-dev-and-managed-identity.ps1` | Upload/query documents, run ACL-trimmed queries |

<details>
<summary><b>Client secret vs. federated credential — what each is for</b></summary>

The script provisions **two** credentials on the app.

**Client secret — required (the auth path the pipeline actually uses).** The SharePoint indexer
runs headless, so it authenticates to SharePoint / Microsoft Graph **app-only** using the app's
client ID + secret, passed inside `SHAREPOINT_CONNECTION_STRING`:

```
SharePointOnlineEndpoint=https://<tenant>.sharepoint.com/sites/<site>;ApplicationId=<appId>;ApplicationSecret=<clientSecret>;TenantId=<tenantId>
```

That app-only token lets the indexer read document content **and** each item's Entra user/group
object IDs (via `User.Read.All`) into the `UserIds` / `GroupIds` ACL fields. The secret is issued
for **1 year** — rotate it (`az ad app credential reset --id <appId>`) before it expires.

**Federated credential — optional (secretless / native-site-group path).** A
workload-identity-federation credential that **trusts the search service's managed identity**:

| Field | Value |
|---|---|
| `issuer` | `https://login.microsoftonline.com/<tenantId>/v2.0` |
| `subject` | the search service managed identity principal ID |
| `audience` | `api://AzureADTokenExchange` |

It lets the search MI exchange its own token for an app-only token with no stored secret — the basis
for the secretless connection option and for resolving **native SharePoint site groups** at query
time. The shipped connection string uses the client secret, so this credential is optional; delete
it if unused (`az ad app federated-credential delete --id <appObjectId> --federated-credential-id <name>`).

</details>

<details>
<summary><b>Why <code>Sites.FullControl.All</code> — and how to avoid it entirely</b></summary>

The app only needs `Sites.Selected` at runtime. But granting an app `Sites.Selected` `read` on a
site is itself a **write** to that site's permissions
(`POST https://graph.microsoft.com/v1.0/sites/{id}/permissions`), which Microsoft Graph requires
**`Sites.FullControl.All`** for — there is no lesser Graph permission that can write a site grant.

`setup-app-registration.ps1` therefore **bootstraps and immediately reverts**: it adds
`Sites.FullControl.All`, admin-consents, uses the app's *own* app-only token to write the one `read`
grant, then **removes `Sites.FullControl.All`**. The steady-state permission set is only the four
`Application` roles above.

**Prefer the app to never hold it, even briefly?** Have a SharePoint/Graph admin perform the
per-site grant manually with PnP PowerShell, then delete the `Grant-AppSiteAccess` bootstrap block
(and its call) from `setup-app-registration.ps1`:

```powershell
Grant-PnPAzureADAppSitePermission -AppId <appId> -DisplayName spmm-sharepoint-acl `
    -Site https://<tenant>.sharepoint.com/sites/<site> -Permissions Read
```

</details>

<details>
<summary><b>Assigning the grants manually (if not using the scripts)</b></summary>

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

`<foundryResourceId>`, `<searchServiceResourceId>`, and `<searchIdentityPrincipalId>` are Bicep
outputs (`az deployment group show -g <rg> -n main --query properties.outputs`).

</details>

### 3. End-user query permissions

At query time, results are ACL-trimmed. **Two tokens** are involved on the query call:

- `Authorization: Bearer <token>` — authenticates the caller to the search data plane. The **calling
  identity** (the user, or a middle-tier app querying on their behalf) needs the **`Search Index
  Data Reader`** Azure RBAC role on the search service.
- `x-ms-query-source-authorization: Bearer <token>` — the end user's token, used **only** for ACL
  trimming. The end user needs no Azure RBAC role; their access is governed entirely by SharePoint
  permissions, which Azure AI Search enforces.

Without the `x-ms-query-source-authorization` header the query returns only documents shared broadly
in SharePoint (verified: 10 public rows vs 86 with the header).

---

## How to deploy

Pick the option that matches who's running it and what already exists:

| Option | Use when |
|---|---|
| [A — one command](#option-a--one-command-super-admin) | One operator holds every role (RG Contributor + Owner/UAA + App/Privileged-Role admin). |
| [B — split developer/admin](#option-b--split-developer-vs-admin) | Deploy rights and admin-consent/RBAC rights belong to different people. |
| [C — existing Search + Foundry](#option-c--existing-search--foundry) | The search service and a Foundry account already exist; you only want the index. |
| [D — without the Vision skill](#option-d--without-the-vision-skill-eg-eastus2) | You must deploy to a region without Vision multimodal embeddings (e.g. `eastus2`). |

`deploy.ps1` is a thin orchestrator that runs four per-phase scripts in order — the same scripts
Option B runs individually:

1. **`scripts/deploy-infra.ps1`** — Bicep (search + Foundry + models); writes non-secret `.env`.
2. **`scripts/setup-app-registration.ps1`** — app registration, Graph/SharePoint permissions, admin
   consent, client secret, federated credential, and per-site `read` grant;
   appends `SHAREPOINT_CONNECTION_STRING` to `.env`.
3. **`scripts/grant-dev-and-managed-identity.ps1`** — grants the developer the two search data-plane
   roles + the search managed identity *Cognitive Services User* on the Foundry.
4. **`scripts/build-index.ps1`** — `pip install -r requirements.txt`, then `build_index.py build`
   (datasource, index, skillset, indexer — auto-runs) and polls status.

### Option A — one command (super admin)

If a single operator is **Contributor** on the RG **and** an **App/Privileged-Role admin** **and**
**Owner/User Access Administrator**, they can do everything in one shot:

```powershell
./deploy.ps1 -ResourceGroup rg-spmm -Location eastus `
             -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>"
```

Add `-SkipAppRegistration -SkipIndex` to stop after provisioning infra.

### Option B — split: developer vs. admin

Keeps duties separate. Run the four per-phase scripts by hand, handing off between phases:

| Phase | Who | Rights needed | Script |
|---|---|---|---|
| **1. Infra** | Developer | Contributor on the RG | **`scripts/deploy-infra.ps1`** → Bicep (search + Foundry + models) + writes `.env`; prints MI principalId + resource IDs |
| **2. App reg** | Admin | App/Privileged-Role admin | **`scripts/setup-app-registration.ps1`** → app registration, Graph/SharePoint perms, **admin consent**, client secret, federated cred, per-site `read` grant → appends `SHAREPOINT_CONNECTION_STRING` |
| **3. Roles** | Admin | Owner/UAA on the search service **+** Foundry | **`scripts/grant-dev-and-managed-identity.ps1`** → developer *Search Service Contributor* + *Search Index Data Contributor*, search MI *Cognitive Services User* |
| **4. Build** | Developer | The 2 Search roles granted in Phase 3 | **`scripts/build-index.ps1`** (`build_index.py build` / `status`) |

**Phase 1 — Developer: provision infra only.**

```powershell
./scripts/deploy-infra.ps1 -ResourceGroup rg-spmm -Location eastus
```

No Entra work, no RBAC, no index build. It writes the resource IDs the admin needs for Phases 2–3
to `.env` (`AZURE_SEARCH_IDENTITY_PRINCIPAL_ID`, `AZURE_FOUNDRY_RESOURCE_ID`,
`AZURE_SEARCH_SERVICE_RESOURCE_ID`) and prints them. You can also re-read them, plus your own
principal id, with:

```powershell
az deployment group show -g rg-spmm -n main --query properties.outputs   # searchIdentityPrincipalId, foundryResourceId, searchServiceResourceId
az ad signed-in-user show --query id -o tsv                              # your object id -> give to the admin
```

**Phase 2 — Admin: app registration + site grants.**

```powershell
./scripts/setup-app-registration.ps1 `
    -SearchIdentityPrincipalId <searchIdentityPrincipalId> `
    -SiteUrls "https://<tenant>.sharepoint.com/sites/<site>" `
    -AppDisplayName spmm-sharepoint-acl
```

If the admin has the developer's `.env` (from Phase 1) on the same machine, they can omit the ID —
the script reads `AZURE_SEARCH_IDENTITY_PRINCIPAL_ID` from it. `-AppDisplayName` names the Entra app
registration (default `spmm-sharepoint-acl`, independent of the infra `-BaseName`). The script appends
`SHAREPOINT_CONNECTION_STRING` to `.env`; hand that back to the developer (the client secret is
shown only once — share it securely).

**Phase 3 — Admin: grant developer + search-MI roles.**

```powershell
./scripts/grant-dev-and-managed-identity.ps1 `
    -SearchServiceResourceId <searchServiceResourceId> `
    -SearchIdentityPrincipalId <searchIdentityPrincipalId> `
    -FoundryResourceId <foundryResourceId> `
    -DeveloperPrincipalId <developer object id>
```

All three resource ids are also read from `.env` (`AZURE_SEARCH_SERVICE_RESOURCE_ID` /
`AZURE_SEARCH_IDENTITY_PRINCIPAL_ID` / `AZURE_FOUNDRY_RESOURCE_ID`) when omitted.

**Phase 4 — Developer: build the index.**

```powershell
./scripts/build-index.ps1
```

This installs the Python deps and runs `build_index.py build` + `status`. It reads `.env` but never
writes it, so it's safe to re-run.

> ⚠️ For Phase 4 use `scripts/build-index.ps1` (or `python scripts/build_index.py build`) — do
> **not** re-run `deploy.ps1`/`deploy-infra.ps1`, which rewrite `.env` from the infra outputs and
> would overwrite the admin-supplied `SHAREPOINT_CONNECTION_STRING`.

> Prefer a notebook? **`notebooks/01_setup_index.ipynb`** performs the exact same build (datasource →
> index → skillset → indexer → run → verify) as clean, `.env`-driven REST calls — a readable
> alternative to `build_index.py`.

### Option C — existing Search + Foundry

If the Azure AI Search service and a Foundry (AI Services) account **already exist**, skip Bicep.
The search service must be in a **Vision-capable region** (e.g. `eastus`), and the Foundry account
must have the `text-embedding-3-large` and `gpt-4.1-mini` deployments (any such Foundry works — it
need not share a region or resource group with the search service, because billing uses a keyless
connection).

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

# 3. Grant yourself the data-plane roles to create objects and run ACL-trimmed queries
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

### Option D — without the Vision skill (e.g. `eastus2`)

To index in a region without Vision multimodal embeddings, drop the Vision pieces. You keep text
chunking, text embeddings, image **extraction** + inline **verbalization**, base64 image rendering,
and ACL trimming; you lose only text→image vector similarity search. Remove from
`scripts/build_index.py` (or a copy):

- the `imageVector` field, the `image-profile` vector profile, and the `vision-vectorizer`
  vectorizer (in `build_index`);
- the `image_embed` (`#Microsoft.Skills.Vision.VectorizeSkill`) skill (in `build_skillset`);
- the `imageVector` mapping from the image index-projection selector.

Because field removal isn't allowed on an existing index, delete the index first if it already
exists (`DELETE indexes/<name>`), then re-run `build`.

---

## Querying with ACL trimming

Every query must forward the caller's identity in the **`x-ms-query-source-authorization`** header,
or Search returns only public (`["all"]`) documents:

```python
headers = {
    "Authorization": f"Bearer {search_token}",       # authenticates the caller
    "x-ms-query-source-authorization": user_token,   # identity used for ACL trimming
}
```

See **`notebooks/demo_retrieval_and_images.ipynb`** for a full walkthrough: full-text retrieval,
semantic retrieval, **text→image vector search**, and **rendering the extracted images inline**.

---

## Repo layout

```
infra/
  main.bicep, main.bicepparam
  modules/search.bicep, modules/foundry.bicep
scripts/
  deploy-infra.ps1             # Phase 1: Bicep infra + writes .env
  setup-app-registration.ps1        # Phase 2: SharePoint app + permissions + site grants
  grant-dev-and-managed-identity.ps1 # Phase 3: developer Search roles + search MI Cognitive Services User
  build-index.ps1              # Phase 4: pip install + build_index.py build/status
  build_index.py               # datasource / index / skillset / indexer + query
deploy.ps1                     # orchestrator: runs the four phase scripts in order
notebooks/
  01_setup_index.ipynb           # build the 4 search resources via REST (.env-driven)
  demo_retrieval_and_images.ipynb
```
