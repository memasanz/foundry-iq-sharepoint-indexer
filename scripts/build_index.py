"""Standalone builder for the multimodal, ACL-trimmed SharePoint index.

Creates (or updates) the datasource, index, skillset and indexer that together produce a rich
multimodal index over a SharePoint library while preserving Entra ACL security trimming:

  - #Microsoft.Skills.Util.ContentUnderstandingSkill  - semantic chunking + page metadata +
    embedded-image extraction + INLINE image verbalization (modelName / modelDeployment).
  - #Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill   - text contentVector (3072-dim).
  - #Microsoft.Skills.Vision.VectorizeSkill            - image imageVector (Azure AI Vision, 1024-dim).
  - Two index-projection selectors emit kind="text" and kind="image" rows, each carrying the
    document's SharePoint metadata + UserIds / GroupIds ACL collections.

Index schema (matches the multimodal RAG shape):
  id, parent_id, parent_id_img, kind, content, contentVector(3072), imageVector(1024),
  imagePath, imageData, page, pageTo, sourceFile, metadata_spo_item_id, webUrl,
  metadata_spo_item_path, lastModified, UserIds, GroupIds

Auth: keyless via DefaultAzureCredential (needs Search Service Contributor + Search Index Data
Contributor on the search service). The search MI needs "Cognitive Services User" on the Foundry
resource - both are wired by scripts/setup-app-registration.ps1.

Usage:
  python scripts/build_index.py build     # datasource + index + skillset + indexer (auto-runs)
  python scripts/build_index.py run       # re-run the indexer
  python scripts/build_index.py status    # poll indexer status
  python scripts/build_index.py docs      # sample indexed rows (text + image)
  python scripts/build_index.py query "*" # ACL-trimmed query forwarding your identity
"""
import os
import sys
import time
from collections import Counter

import requests
from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential

load_dotenv()

SEARCH = os.environ["AZURE_SEARCH_ENDPOINT"].rstrip("/")
API = os.environ.get("AZURE_SEARCH_API_VERSION", "2026-05-01-preview")
PREFIX = os.environ.get("RESOURCE_PREFIX", "sharepoint")

DATASOURCE = f"{PREFIX}-nb7-ds"
INDEX = f"{PREFIX}-nb7-index"
SKILLSET = f"{PREFIX}-nb7-skillset"
INDEXER = f"{PREFIX}-nb7-indexer"

SP_CONNECTION_STRING = os.environ["SHAREPOINT_CONNECTION_STRING"]
SP_CONTAINER = os.environ.get("SHAREPOINT_CONTAINER_NAME", "defaultSiteLibrary")

AOAI_ENDPOINT = os.environ["AZURE_OPENAI_ENDPOINT"].rstrip("/")
EMBED_DEPLOYMENT = os.environ["AZURE_OPENAI_EMBEDDING_DEPLOYMENT"]
EMBED_MODEL = os.environ["AZURE_OPENAI_EMBEDDING_MODEL"]
EMBED_DIMENSIONS = int(os.environ.get("AZURE_OPENAI_EMBEDDING_DIMENSIONS", "3072"))

GPT_DEPLOYMENT = os.environ["AZURE_OPENAI_GPT_DEPLOYMENT"]
GPT_MODEL = os.environ["AZURE_OPENAI_GPT_MODEL"]

AI_SERVICES_ENDPOINT = os.environ["AZURE_AI_SERVICES_ENDPOINT"].rstrip("/")
VISION_MODEL_VERSION = os.environ.get("AZURE_AI_VISION_MODEL_VERSION", "2023-04-15")
VISION_DIMENSIONS = 1024  # fixed by the Azure AI Vision multimodal embeddings API

_cred = DefaultAzureCredential()


def _token():
    return _cred.get_token("https://search.azure.com/.default").token


def rest(method, path, body=None, extra_headers=None):
    url = f"{SEARCH}/{path}?api-version={API}"
    headers = {"Authorization": f"Bearer {_token()}", "Content-Type": "application/json"}
    if extra_headers:
        headers.update(extra_headers)
    resp = requests.request(method, url, headers=headers, json=body)
    if not resp.ok:
        print(f"!! {method} {path} -> {resp.status_code}\n{resp.text[:1800]}")
        resp.raise_for_status()
    if resp.text and resp.headers.get("content-type", "").startswith("application/json"):
        return resp.json()
    return {}


def build_datasource():
    rest("PUT", f"datasources/{DATASOURCE}", {
        "name": DATASOURCE,
        "type": "sharepoint",
        "credentials": {"connectionString": SP_CONNECTION_STRING},
        "container": {"name": SP_CONTAINER, "query": None},
        "indexerPermissionOptions": ["userIds", "groupIds"],
    })
    print("datasource ok:", DATASOURCE)


def build_index():
    index = {
        "name": INDEX,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "analyzer": "keyword",
             "searchable": True, "filterable": True, "sortable": True, "retrievable": True},
            {"name": "parent_id", "type": "Edm.String", "filterable": True, "retrievable": True},
            {"name": "parent_id_img", "type": "Edm.String", "filterable": True, "retrievable": True},
            {"name": "kind", "type": "Edm.String", "filterable": True, "facetable": True, "retrievable": True},
            {"name": "content", "type": "Edm.String", "searchable": True, "analyzer": "standard.lucene",
             "retrievable": True},
            {"name": "contentVector", "type": "Collection(Edm.Single)", "searchable": True,
             "retrievable": False, "dimensions": EMBED_DIMENSIONS, "vectorSearchProfile": "text-profile"},
            {"name": "imageVector", "type": "Collection(Edm.Single)", "searchable": True,
             "retrievable": False, "dimensions": VISION_DIMENSIONS, "vectorSearchProfile": "image-profile"},
            {"name": "imagePath", "type": "Edm.String", "retrievable": True},
            {"name": "imageData", "type": "Edm.String", "retrievable": True,
             "searchable": False, "filterable": False, "sortable": False, "facetable": False},
            {"name": "page", "type": "Edm.Int32", "filterable": True, "sortable": True,
             "facetable": True, "retrievable": True},
            {"name": "pageTo", "type": "Edm.Int32", "filterable": True, "sortable": True,
             "facetable": True, "retrievable": True},
            {"name": "sourceFile", "type": "Edm.String", "searchable": True, "analyzer": "standard.lucene",
             "filterable": True, "facetable": True, "retrievable": True},
            {"name": "metadata_spo_item_id", "type": "Edm.String", "filterable": True, "retrievable": True},
            {"name": "webUrl", "type": "Edm.String", "retrievable": True},
            {"name": "metadata_spo_item_path", "type": "Edm.String", "retrievable": True},
            {"name": "lastModified", "type": "Edm.DateTimeOffset", "filterable": True, "sortable": True,
             "facetable": True, "retrievable": True},
            {"name": "UserIds", "type": "Collection(Edm.String)", "permissionFilter": "userIds",
             "filterable": True, "retrievable": False},
            {"name": "GroupIds", "type": "Collection(Edm.String)", "permissionFilter": "groupIds",
             "filterable": True, "retrievable": False},
        ],
        "permissionFilterOption": "enabled",
        "vectorSearch": {
            "algorithms": [{"name": "hnsw", "kind": "hnsw",
                            "hnswParameters": {"m": 4, "efConstruction": 400, "metric": "cosine"}}],
            "vectorizers": [
                {"name": "aoai-vectorizer", "kind": "azureOpenAI",
                 "azureOpenAIParameters": {"resourceUri": AOAI_ENDPOINT,
                                           "deploymentId": EMBED_DEPLOYMENT, "modelName": EMBED_MODEL}},
                {"name": "vision-vectorizer", "kind": "aiServicesVision",
                 "aiServicesVisionParameters": {"resourceUri": AI_SERVICES_ENDPOINT,
                                                "authIdentity": None, "modelVersion": VISION_MODEL_VERSION}},
            ],
            "profiles": [
                {"name": "text-profile", "algorithm": "hnsw", "vectorizer": "aoai-vectorizer"},
                {"name": "image-profile", "algorithm": "hnsw", "vectorizer": "vision-vectorizer"},
            ],
        },
        "semantic": {
            "defaultConfiguration": "semantic-config",
            "configurations": [{"name": "semantic-config", "prioritizedFields": {
                "titleField": {"fieldName": "sourceFile"},
                "prioritizedContentFields": [{"fieldName": "content"}]}}],
        },
    }
    rest("PUT", f"indexes/{INDEX}", index)
    print("index ok:", INDEX)


def build_skillset():
    content_understanding = {
        "@odata.type": "#Microsoft.Skills.Util.ContentUnderstandingSkill",
        "name": "content-understanding",
        "description": "Semantic chunking + page metadata + image extraction + inline image verbalization.",
        "context": "/document",
        "extractionOptions": ["images", "locationMetadata"],
        "chunkingProperties": {"method": "semantic", "unit": "tokens", "maximumLength": 800,
                               "overlapLength": 0},
        "modelName": GPT_MODEL,
        "modelDeployment": GPT_DEPLOYMENT,
        "inputs": [{"name": "file_data", "source": "/document/file_data"}],
        "outputs": [
            {"name": "text_sections", "targetName": "text_sections"},
        ],
    }

    text_embed = {
        "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
        "name": "text-embed", "context": "/document/text_sections/*",
        "resourceUri": AOAI_ENDPOINT, "deploymentId": EMBED_DEPLOYMENT,
        "modelName": EMBED_MODEL, "dimensions": EMBED_DIMENSIONS,
        "inputs": [{"name": "text", "source": "/document/text_sections/*/content"}],
        "outputs": [{"name": "embedding", "targetName": "content_vector"}],
    }

    image_embed = {
        "@odata.type": "#Microsoft.Skills.Vision.VectorizeSkill",
        "name": "image-embed", "context": "/document/normalized_images/*",
        "modelVersion": VISION_MODEL_VERSION,
        # /document/normalized_images/* comes from the indexer's imageAction
        # (generateNormalizedImages), which also populates base64 `data` per image.
        "inputs": [{"name": "image", "source": "/document/normalized_images/*"}],
        "outputs": [{"name": "vector", "targetName": "image_vector"}],
    }

    kind_text = {
        "@odata.type": "#Microsoft.Skills.Util.ConditionalSkill", "name": "kind-text",
        "context": "/document/text_sections/*",
        "inputs": [{"name": "condition", "source": "= true"},
                   {"name": "whenTrue", "source": "= 'text'"},
                   {"name": "whenFalse", "source": "= 'text'"}],
        "outputs": [{"name": "output", "targetName": "kind"}],
    }
    kind_image = {
        "@odata.type": "#Microsoft.Skills.Util.ConditionalSkill", "name": "kind-image",
        "context": "/document/normalized_images/*",
        "inputs": [{"name": "condition", "source": "= true"},
                   {"name": "whenTrue", "source": "= 'image'"},
                   {"name": "whenFalse", "source": "= 'image'"}],
        "outputs": [{"name": "output", "targetName": "kind"}],
    }

    doc_meta = [
        {"name": "sourceFile", "source": "/document/metadata_spo_item_name"},
        {"name": "metadata_spo_item_id", "source": "/document/metadata_spo_item_id"},
        {"name": "webUrl", "source": "/document/metadata_spo_item_weburi"},
        {"name": "metadata_spo_item_path", "source": "/document/metadata_spo_item_path"},
        {"name": "lastModified", "source": "/document/metadata_spo_item_last_modified"},
        {"name": "UserIds", "source": "/document/metadata_user_ids"},
        {"name": "GroupIds", "source": "/document/metadata_group_ids"},
    ]

    skillset = {
        "name": SKILLSET,
        "description": "CU (semantic chunks + image extraction) -> text + image vectors; project ACLs.",
        "skills": [content_understanding, text_embed, image_embed, kind_text, kind_image],
        "cognitiveServices": {"@odata.type": "#Microsoft.Azure.Search.AIServicesByIdentity",
                              "subdomainUrl": AI_SERVICES_ENDPOINT},
        "indexProjections": {
            "selectors": [
                {
                    "targetIndexName": INDEX,
                    "parentKeyFieldName": "parent_id",
                    "sourceContext": "/document/text_sections/*",
                    "mappings": [
                        {"name": "content", "source": "/document/text_sections/*/content"},
                        {"name": "contentVector", "source": "/document/text_sections/*/content_vector"},
                        {"name": "kind", "source": "/document/text_sections/*/kind"},
                        {"name": "imagePath", "source": "/document/text_sections/*/imagePath"},
                        {"name": "page", "source": "/document/text_sections/*/locationMetadata/pageNumberFrom"},
                        {"name": "pageTo", "source": "/document/text_sections/*/locationMetadata/pageNumberTo"},
                    ] + doc_meta,
                },
                {
                    "targetIndexName": INDEX,
                    "parentKeyFieldName": "parent_id_img",
                    "sourceContext": "/document/normalized_images/*",
                    "mappings": [
                        {"name": "imageData", "source": "/document/normalized_images/*/data"},
                        {"name": "imageVector", "source": "/document/normalized_images/*/image_vector"},
                        {"name": "kind", "source": "/document/normalized_images/*/kind"},
                        {"name": "page", "source": "/document/normalized_images/*/pageNumber"},
                        {"name": "pageTo", "source": "/document/normalized_images/*/pageNumber"},
                    ] + doc_meta,
                },
            ],
            "parameters": {"projectionMode": "skipIndexingParentDocuments"},
        },
    }
    rest("PUT", f"skillsets/{SKILLSET}", skillset)
    print("skillset ok:", SKILLSET)


def build_indexer():
    rest("PUT", f"indexers/{INDEXER}", {
        "name": INDEXER,
        "dataSourceName": DATASOURCE,
        "targetIndexName": INDEX,
        "skillsetName": SKILLSET,
        "parameters": {
            "batchSize": 1,
            "maxFailedItems": 5,
            "maxFailedItemsPerBatch": 5,
            "configuration": {
                "dataToExtract": "contentAndMetadata",
                "allowSkillsetToReadFileData": True,
                # Populate /document/normalized_images/*/data (base64) so image bytes can be
                # inlined into the index (imageData) and rendered directly - no knowledge store.
                "imageAction": "generateNormalizedImages",
            },
        },
        "fieldMappings": [],
        "outputFieldMappings": [],
    })
    print("indexer ok (auto-run started):", INDEXER)


def status(poll=False):
    for _ in range(90 if poll else 1):
        j = rest("GET", f"indexers/{INDEXER}/status")
        last = j.get("lastResult") or {}
        print(f"status={j.get('status')} last={last.get('status')} "
              f"processed={last.get('itemsProcessed')} failed={last.get('itemsFailed')}")
        done = (last.get("status") or "").lower() in ("success", "transientfailure") and last.get("endTime")
        if done or not poll:
            for e in (last.get("errors") or [])[:5]:
                print("ERR:", e.get("key"), (e.get("errorMessage") or "")[:220])
            for w in (last.get("warnings") or [])[:5]:
                print("WARN:", (w.get("message") or "")[:160])
            if done:
                break
        if poll:
            time.sleep(20)


def query(text="*", as_user=True):
    headers = {}
    if as_user:
        headers["x-ms-query-source-authorization"] = _token()
    r = rest("POST", f"indexes/{INDEX}/docs/search", {
        "search": text, "count": True, "top": 1000,
        "select": "kind,sourceFile,page,pageTo,content,imagePath",
    }, extra_headers=headers)
    rows = r.get("value", [])
    print("total rows:", r.get("@odata.count"), "(as_user=", as_user, ")")
    print("by kind   :", dict(Counter(d.get("kind") for d in rows)))
    for d in rows[:6]:
        if d.get("kind") == "text":
            print(f"  [text ] {d.get('sourceFile')} p.{d.get('page')}-{d.get('pageTo')} | "
                  f"{(d.get('content') or '')[:70]!r}")
        else:
            print(f"  [image] {d.get('sourceFile')} p.{d.get('page')} {d.get('imagePath')}")


def main():
    step = sys.argv[1] if len(sys.argv) > 1 else "build"
    if step == "build":
        build_datasource()
        build_index()
        build_skillset()
        build_indexer()
    elif step == "run":
        rest("POST", f"indexers/{INDEXER}/run")
        print("run started")
    elif step == "status":
        status(poll=True)
    elif step == "docs":
        query("*", as_user=True)
    elif step == "query":
        query(sys.argv[2] if len(sys.argv) > 2 else "*", as_user=True)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
