# Two gateways, one MaaS — RHOAI 3.4

Expose **one** Red Hat OpenShift AI **Models-as-a-Service (MaaS)** deployment through
**two independent gateways** (two external IPs / hostnames). The same MaaS-managed
models and the same MaaS API keys work through either gateway — useful when a
"highly-secure" client network and a "secure" client network must reach the models on
**separate entry points / firewalls**, while the models, keys, and governance stay in a
single MaaS control plane.

> MaaS itself manages only its own `maas-default-gateway`. The second gateway is added
> manually (routes + mirrored auth). This works because MaaS key validation is a
> cluster-internal, gateway-agnostic call. It is **not** a Red Hat-supported topology,
> and token quota is enforced **per gateway** (it does not aggregate across the two) —
> acceptable when the two gateways are separate trust zones.

Validated live on OCP 4.20 / RHOAI 3.4, 4× NVIDIA L40S, vLLM `0.18.0+rhaiv.7`.

---

## Architecture

```
   highly-secure network                          general network
          │ https                                        │ https
          ▼                                               ▼
 ┌───────────────────────────┐               ┌───────────────────────────┐
 │  secure-gateway           │               │  maas-default-gateway     │
 │  secure.apps.<domain>     │               │  maas.apps.<domain>       │
 │  IP: <ELB-A>              │               │  IP: <ELB-B>              │
 │                           │               │                           │
 │  HTTPRoutes   (manual)    │               │  HTTPRoutes   (by MaaS)   │
 │  AuthPolicy   (mirrored)  │               │  AuthPolicy   (by MaaS)   │
 │  TokenRateLimitPolicy     │               │  maas-api  →  /maas-api   │
 └────────────┬──────────────┘               └─────────────┬─────────────┘
              │                                             │
              │   both enforce the SAME MaaS API keys via the internal,
              │   gateway-agnostic call: maas-api/internal/v1/api-keys/validate
              └──────────────────────┬──────────────────────┘
                                     ▼
                  ┌────────────────────────────────────────┐
                  │  ONE MaaS control plane (cluster-singleton)
                  │  maas-api · Authorino · Limitador · PostgreSQL
                  └────────────────────┬───────────────────┘
                                       ▼
                  ┌────────────────────────────────────────┐
                  │  MaaS-managed models  (namespace demo-llm)
                  │    qwen-3     chat / generative  (llm-d)
                  │    bge-embed  embeddings         (vLLM)
                  └────────────────────────────────────────┘

  Mint a key once (only the MaaS gateway exposes maas-api). That key is then
  accepted at BOTH gateways:  no key → 401   invalid → 403   valid → 200
```

**How it works.** Each MaaS model's Kuadrant `AuthPolicy` validates the API key by
calling `maas-api.../internal/v1/api-keys/validate` — independent of which gateway the
request entered. So we add HTTPRoutes for the same model backends on the second gateway
and *copy* the MaaS-generated `AuthPolicy` (and `TokenRateLimitPolicy`) onto them. Key
minting stays only on the MaaS gateway; clients mint once and use either gateway.

---

## Prerequisites

- RHOAI 3.4 with the **MaaS platform installed** — Connectivity Link/Kuadrant,
  `modelsAsService` on the DSC, `maas-default-gateway`, PostgreSQL, Authorino TLS.
  Follow **`https://github.com/rh-aiservices-bu/RHOAI-MaaS-Embedding-Model`**.
- GPU nodes (1 GPU per model replica), `oc` (cluster-admin), `python3` (mirror script),
  `envsubst` (from `gettext`, for hostname templating).
- Hostnames are **not** hardcoded. `01`, `02`, `05` template the host as
  `maas.${APPS_DOMAIN}` / `secure.${APPS_DOMAIN}`; you fill `APPS_DOMAIN` from the live
  cluster and render with `envsubst` (see Deploy). This makes a wrong/foreign hostname
  impossible. The default `*.apps` wildcard cert covers both `maas.` and `secure.` hosts.

---

## Files

| File | Purpose |
|------|---------|
| `01-maas-gateway.yaml` | Gateway 1 — `maas-default-gateway` (usually created by the MaaS install; for reference) |
| `02-second-gateway.yaml` | Gateway 2 — `secure-gateway`, its own IP + hostname |
| `03-models.yaml` | MaaS models: `qwen-3` (chat, llm-d) + `bge-embed` (embeddings, plain vLLM) |
| `04-maas-publish-and-subscription.yaml` | Publish both models + subscription + auth policy |
| `05-second-gateway-routes.yaml` | HTTPRoutes exposing the same models on gateway 2 |
| `mirror-maas-policies.sh` | Copies each model's MaaS auth + quota policy onto the gateway-2 routes |

---

## Deploy

```bash
# 0. MaaS platform must already be installed (see Prerequisites).
#    Read the apps domain from THIS cluster (do not type it by hand):
export APPS_DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
echo "APPS_DOMAIN=$APPS_DOMAIN"          # must be non-empty, e.g. apps.cluster-xxxx.<...>.com

# 1. Gateways (envsubst fills the templated hostnames):
envsubst < 01-maas-gateway.yaml | oc apply -f -   # skip if the platform install already created it
envsubst < 02-second-gateway.yaml | oc apply -f -

# 2. Models, then publish + subscribe
oc apply -f 03-models.yaml
oc apply -f 04-maas-publish-and-subscription.yaml
oc -n demo-llm wait --for=condition=Ready llminferenceservice/qwen-3 --timeout=600s
oc -n demo-llm wait --for=condition=Ready llminferenceservice/bge-embed --timeout=600s

# 3. Expose the same models on gateway 2 + mirror auth/quota onto those routes
envsubst < 05-second-gateway-routes.yaml | oc apply -f -
bash mirror-maas-policies.sh
```

> `envsubst` only substitutes `${APPS_DOMAIN}`; if it's unset the rendered hostname
> becomes `maas.`/`secure.` and the Gateway won't program — set it first. Never
> `oc apply -f` these three files directly (that ships the literal `${APPS_DOMAIN}`).

---

## Demonstrate: one key, both gateways

```bash
APPS_DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')   # from the cluster
MAAS=maas.$APPS_DOMAIN          # gateway 1 (MaaS-managed)
SECURE=secure.$APPS_DOMAIN      # gateway 2 (manual mirror)

# Mint ONE key (maas-api is exposed only on the MaaS gateway). oc token authenticates minting.
KEY=$(curl -sk -X POST https://$MAAS/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
  -d '{"name":"two-gw-demo"}' | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
echo "key: ${KEY:0:14}..."

# Generative model — same key, through EACH gateway (expect 200 both)
for H in $MAAS $SECURE; do
  echo "== qwen-3 via $H =="
  curl -sk https://$H/demo-llm/qwen-3/v1/chat/completions \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d '{"model":"qwen-3","messages":[{"role":"user","content":"reply with: pong"}],"max_tokens":16}' \
    -w '\n-> HTTP %{http_code}\n'
done

# Embeddings model — same key, through EACH gateway (expect 200 both, 768-dim vectors)
for H in $MAAS $SECURE; do
  echo "== bge-embed via $H =="
  curl -sk https://$H/demo-llm/bge-embed/v1/embeddings \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d '{"model":"bge-embed","input":["the quick brown fox","models as a service"]}' \
    -w '\n-> HTTP %{http_code}\n'
done

# Auth is enforced on BOTH gateways
for H in $MAAS $SECURE; do
  echo "== $H : no key (expect 401) / bad key (expect 403) =="
  curl -sk -o /dev/null -w '  no-key  -> %{http_code}\n' -X POST \
    https://$H/demo-llm/qwen-3/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"qwen-3","messages":[{"role":"user","content":"hi"}],"max_tokens":4}'
  curl -sk -o /dev/null -w '  bad-key -> %{http_code}\n' -X POST \
    https://$H/demo-llm/qwen-3/v1/chat/completions \
    -H 'Authorization: Bearer sk-oai-bogus' -H 'Content-Type: application/json' \
    -d '{"model":"qwen-3","messages":[{"role":"user","content":"hi"}],"max_tokens":4}'
done
```

Expected:

```
key: sk-oai-XXXXXXX...
== qwen-3 via maas.apps...   ==  ... -> HTTP 200
== qwen-3 via secure.apps... ==  ... -> HTTP 200
== bge-embed via maas.apps...   ==  "object":"list","data":[{"embedding":[...768 floats...]}]  -> HTTP 200
== bge-embed via secure.apps... ==  ...                                                        -> HTTP 200
== maas.apps...   : no-key -> 401   bad-key -> 403
== secure.apps... : no-key -> 401   bad-key -> 403
```

A key minted once is honored at both gateways, for both models, with auth enforced at
each gateway before the model.

---

## Notes

- **Manual & unsupported.** MaaS only auto-manages `maas-default-gateway`; you own the
  gateway-2 routes and the mirrored policies. Re-run `mirror-maas-policies.sh` after
  re-publishing a model.
- **Quota is per gateway, not shared.** Limitador namespaces token counters per
  HTTPRoute, so each gateway enforces the budget independently (a client gets the full
  budget on each). Fine when the two gateways are separate trust zones; if you need a
  single shared budget across both, use one gateway.
- **Key minting** is only on the MaaS gateway (`/maas-api`); the second gateway serves
  inference only.
