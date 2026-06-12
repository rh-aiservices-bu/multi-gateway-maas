# Option B on RHOAI 3.4 — validated demo

Reproducible manifests + findings for the "Option B" multi-gateway architecture on
Red Hat OpenShift AI 3.4. Two supported scenarios are locked in here:

- **Scenario A — B2:** two *separate* Gateway-API gateways (two external IPs), each
  with its own `LLMInferenceService` (plain llm-d), hard-isolated.
- **Scenario B — MaaS:** one `maas-default-gateway` serving a **generative** model
  (qwen-3, llm-d) **and** an **embeddings** model (bge-embed, plain vLLM), governed by
  MaaS auth + per-model token quota.

Validated live on **OCP 4.20 / RHOAI 3.4, 4× NVIDIA L40S, vLLM `0.18.0+rhaiv.7`**
(`cluster-nmv4m.nmv4m.sandbox1140.opentlc.com`), 2026-06-12.

> Findings that ruled options *out* (two MaaS deployments; two gateways sharing one
> MaaS) are preserved in **Limitations** below — the exploratory manifests that proved
> them were removed during tidy-up; the conclusions are what matter.

---

## Prerequisites

- RHOAI 3.4 self-managed, cluster-admin.
- GPU nodes (NVIDIA GPU Operator + NFD). Each model replica needs 1 GPU.
- **For Scenario B (MaaS):** the MaaS platform must be installed first — Connectivity
  Link/Kuadrant, `modelsAsService` enabled on the DSC, `maas-default-gateway`,
  PostgreSQL, Authorino TLS. Follow **`../../rhoai3.4-maas/README.md`** (the operator
  install, Kuadrant CR, DSC, gateway, DB, TLS, and the Kuadrant-operator restart).
- For Scenario A you only need a `GatewayClass` using the OpenShift gateway controller
  (`openshift-default` already exists on a stock cluster).

Edit the apps-domain hostname in `04-maas-gateway.yaml` if you reproduce on another
cluster.

---

## Files

| File | Scenario | Purpose |
|------|----------|---------|
| `01-secure-gateway.yaml` | A (B2) | Second, separate Gateway (`secure-inference`) → its own external IP |
| `02-secure-models-namespace.yaml` | A (B2) | Separate trust-zone namespace |
| `03-secure-model-llmisvc.yaml` | A (B2) | `LLMInferenceService` bound to `secure-inference` via `router.gateway.refs` |
| `04-maas-gateway.yaml` | B (MaaS) | `maas-default-gateway` (hostname set for this cluster) |
| `05-maas-qwen3.yaml` | B (MaaS) | Generative model `qwen-3` (Qwen3-0.6B, llm-d) on the MaaS gateway |
| `06-maas-modelref.yaml` | B (MaaS) | `MaaSModelRef` publishing qwen-3 to the MaaS catalog |
| `07-embeddings-llmisvc.yaml` | B (MaaS) | Embeddings model `bge-embed` (plain vLLM, `--runner pooling`) |
| `08-embeddings-modelref-and-subscription.yaml` | B (MaaS) | Publishes bge-embed + combined subscription/auth-policy (qwen-3 + bge-embed) |

---

## Scenario A — two separate gateways (B2)  ✅ supported

```bash
oc apply -f 01-secure-gateway.yaml          # second Gateway -> distinct ELB/IP
oc apply -f 02-secure-models-namespace.yaml
oc apply -f 03-secure-model-llmisvc.yaml     # model bound to secure-inference (needs 1 GPU)
```

What it proves:
- A second Gateway provisions its **own external IP** (separate AWS ELB / `LoadBalancer`
  Service), independent of the shared `openshift-ai-inference` gateway.
- `LLMInferenceService.spec.router.gateway.refs` binds a model to a chosen gateway via
  **plain YAML** — no dashboard "gateway discovery" (Tech Preview) flag required.
- **Hard isolation:** a model answers **200 only through its own gateway** and **404
  through the other**. Verified both directions.

> The llm-d / Gateway-selection path is **Technology Preview** in 3.4 — production use
> needs a Red Hat support exception.

---

## Scenario B — MaaS: generative + embeddings on one gateway  ✅ supported

Install the MaaS platform first (see Prerequisites), then:

```bash
oc apply -f 04-maas-gateway.yaml                      # if not already created by the platform install
oc apply -f 05-maas-qwen3.yaml                        # generative model (llm-d)
oc apply -f 06-maas-modelref.yaml                     # publish qwen-3
oc apply -f 07-embeddings-llmisvc.yaml                # embeddings model (plain vLLM)
oc apply -f 08-embeddings-modelref-and-subscription.yaml   # publish bge-embed + subscription/quota
```

Mint a key and test (replace `<DOMAIN>`; `$(oc whoami -t)` authenticates key minting):

```bash
H=maas.apps.<DOMAIN>
KEY=$(curl -sk -X POST https://$H/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
  -d '{"name":"demo"}' | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')

# Generative (llm-d)
curl -sk https://$H/demo-llm/qwen-3/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen-3","messages":[{"role":"user","content":"hello"}],"max_tokens":16}'

# Embeddings (plain vLLM)
curl -sk https://$H/demo-llm/bge-embed/v1/embeddings \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"bge-embed","input":["the quick brown fox","models as a service"]}'
```

Verified results:
- Auth enforced at the gateway before the model: **no key → 401, invalid → 403, valid → 200**.
- qwen-3 `/v1/chat/completions` → 200 real completion. bge-embed `/v1/embeddings` → 200
  with 768-dim vectors and `usage.prompt_tokens` metering.
- Per-model token quota enforced (qwen-3 1000/h, bge-embed 5000/h) → **429** when
  exhausted; the two budgets are independent.

### Why two model shapes
| Model type | Router | Routes `/v1/embeddings`? |
|---|---|---|
| Generative chat | llm-d (`router.scheduler: {}`) → InferencePool | ❌ 404 (generation endpoints only) |
| Embeddings / pooling | **plain vLLM** (omit `router.scheduler`, `--runner pooling`) | ✅ 200 (catch-all route → Service) |

Both deploy as `LLMInferenceService` behind the same gateway with the same governance;
you pick the router shape per model type. `/rerank` and `/score` similarly need a
pooling/cross-encoder model, not the generative backend.

---

## Limitations validated (conclusions kept; exploratory manifests removed)

- **Endpoint support on a generative llm-d model:** `/v1/chat/completions`,
  `/v1/completions`, `/tokenize`, `/detokenize`, `/v1/models` → 200.
  `/v1/embeddings`, `/rerank`, `/score`, `/pooling`, `/v1/audio/speech`, `/v1/realtime`
  → 404 (need a different model type/runtime, or are absent from this vLLM build).
  Requests must use the HF model id, not the route name.

- **Two MaaS deployments (one per gateway) — NOT possible on one cluster.** MaaS is a
  hard singleton: the `Tenant` CRD enforces exactly one tenant named `default-tenant`
  (CEL rule `self.metadata.name == 'default-tenant'`); `maas-api`/`maas-controller` are
  global singletons reading one `maas-parameters` ConfigMap (one gateway) and a
  hardcoded subscription namespace. Two MaaS zones ⇒ two clusters.

- **Two gateways sharing one MaaS — possible but manual & unsupported, and quota does
  not aggregate.** MaaS key validation is a cluster-internal, gateway-agnostic call, so
  a hand-authored route + copied `AuthPolicy` on a second gateway *does* enforce the
  same keys (401/403/200). But Limitador namespaces token counters **per HTTPRoute**, so
  each gateway gets its own counter — a client gets the full quota on *each* gateway
  (N gateways → N× the budget). No supported way to share one counter. If a single
  shared token budget across two IPs is required, use one gateway or separate clusters.

---

## Cluster state (left running; not modified during tidy-up)
- `qwen-tools` (pre-existing demo, Qwen3-4B) scaled to 2 replicas to free GPUs.
- MaaS platform installed; Service Mesh upgraded 3.1 → 3.3 for Kuadrant.
- Running models: `qwen-tools` (shared gateway), `qwen-3` + `bge-embed` (MaaS gateway).
- `secure-inference` gateway exists (Scenario A); its model `03` is not currently
  applied (was removed earlier to free a GPU) — re-apply to demo B2 live.
