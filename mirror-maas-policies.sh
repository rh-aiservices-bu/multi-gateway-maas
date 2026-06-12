#!/usr/bin/env bash
# Mirror MaaS auth + token-quota onto the SECOND gateway's routes.
#
# MaaS generates, for each published model, a Kuadrant AuthPolicy (maas-auth-<m>)
# and TokenRateLimitPolicy (maas-trlp-<m>) attached to that model's MaaS route on
# maas-default-gateway. MaaS validates API keys via a cluster-internal call, so
# those same policies enforce identically when copied onto a route on any other
# gateway. This script copies each policy and retargets it to <model>-secure-route
# (created by 05-second-gateway-routes.yaml).
#
# Re-run after (re)publishing a model. Requires: oc (logged in), python3.
#
# NOTE: token quota does NOT aggregate across gateways — Limitador namespaces
# counters per HTTPRoute, so each gateway enforces the budget independently.
set -euo pipefail

NS=demo-llm
MODELS=(qwen-3 bge-embed)

retarget() {  # <kind> <src-name> <dst-name> <route>
  oc -n "$NS" get "$1" "$2" -o json | python3 -c "
import sys, json
d = json.load(sys.stdin)
out = {
  'apiVersion': d['apiVersion'], 'kind': d['kind'],
  'metadata': {'name': '$3', 'namespace': '$NS',
               'labels': {'demo': 'two-gateways-one-maas'}},
  'spec': d['spec'],
}
out['spec']['targetRef'] = dict(d['spec']['targetRef'])
out['spec']['targetRef']['name'] = '$4'
json.dump(out, sys.stdout)
" | oc apply -f -
}

for M in "${MODELS[@]}"; do
  echo "== mirroring policies for $M -> ${M}-secure-route =="
  retarget authpolicy            "maas-auth-$M" "maas-auth-secure-$M" "${M}-secure-route"
  retarget tokenratelimitpolicy  "maas-trlp-$M" "maas-trlp-secure-$M" "${M}-secure-route"
done

echo "done. check: oc -n $NS get authpolicy,tokenratelimitpolicy -l demo=two-gateways-one-maas"
