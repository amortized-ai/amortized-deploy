# openshell-platform

The OpenShell platform prerequisites for sandboxed Morty on RHOAI/OpenShift, packaged as
one Helm release. This replaces the imperative cluster-admin steps we previously ran and
tracked by hand (the "E1" step) with a single, repeatable `helm install`.

## What it installs

| Piece | Source | Where |
|---|---|---|
| agent-sandbox CRD | `crds/agent-sandbox-crds.yaml` (kubernetes-sigs v0.5.6) | cluster-scoped |
| agent-sandbox controller + RBAC | `templates/agent-sandbox.yaml` (vendored, v0.5.6) | `agent-sandbox-system` |
| OpenShell gateway | `oci://ghcr.io/nvidia/openshell/helm-chart` v0.0.113 (subchart) | release namespace |
| Privileged SCC grant for sandbox pods | `templates/scc-privileged.yaml` | release namespace |

Equivalent imperative steps (now encoded here):

```
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.6/sandbox.yaml
oc create ns openshell
oc adm policy add-scc-to-user privileged -z openshell-sandbox -n openshell
helm install openshell oci://ghcr.io/nvidia/openshell/helm-chart --version 0.0.113 \
  -n openshell --set podSecurityContext.fsGroup=null --set securityContext.runAsUser=null \
  --set server.auth.allowUnauthenticatedUsers=true
```

## Install (cluster-admin, once per cluster)

```
./install.sh            # or: ./install.sh <namespace>   (default: openshell)
```

`install.sh` runs `helm dependency build` + `helm upgrade --install` with the required
OpenShift `--set` flags. Do **not** use a bare `helm install` — see the SCC note below.

Verify with the commands printed in NOTES after install.

## Uninstall (clean, for retesting)

```
./uninstall.sh          # or: ./uninstall.sh <namespace>
```

`helm uninstall` alone is **not** enough — it leaves the agent-sandbox CRD (shipped via
`crds/`, which Helm never deletes) and the `--create-namespace` namespace. `uninstall.sh`
removes everything (Sandbox instances → release → CRD → `openshell` + `agent-sandbox-system`
namespaces), so a subsequent `install.sh` starts from a clean slate. Manual equivalent:

```
oc delete sandboxes.agents.x-k8s.io --all -A --ignore-not-found
helm uninstall openshell-platform -n openshell
oc delete crd sandboxes.agents.x-k8s.io --ignore-not-found
oc delete ns openshell agent-sandbox-system --ignore-not-found
```

## The OpenShift SCC `--set` requirement

The gateway subchart hardcodes `podSecurityContext.fsGroup=1000` and
`securityContext.runAsUser=1000`, which `restricted-v2` rejects (uid outside the namespace
range). They must be cleared so the SCC injects a valid uid — but Helm's subchart value-merge
**ignores a file-level `null`**, so a bare `helm install` fails with a `FailedCreate` SCC error.
`install.sh` clears them via `--set`, which does take effect. (Validated on RHOAI 3.3.1.)

## Notes / caveats

- **Requires cluster-admin** — installs a CRD, a cluster-scoped controller + ClusterRole/Binding,
  and grants the `privileged` SCC.
- **CRD lifecycle:** the agent-sandbox CRD ships under `crds/`. Helm installs it on first
  install but does **not** upgrade or delete it (a Helm limitation). To move agent-sandbox
  versions, update the CRD out of band.
- **`openshell.agentSandbox.preflight.enabled: false`** — the gateway subchart normally probes
  the live cluster for the agent-sandbox API before rendering. Because this release installs
  agent-sandbox itself, the API is not live at render time, so the preflight is disabled here.
- **SA name coupling:** `scc.sandboxServiceAccount` must match the gateway subchart's generated
  sandbox SA (`openshell.fullnameOverride` + `-sandbox`, i.e. `openshell-sandbox`).
- **Gateway auth** is eval-mode: transport mTLS on, API auth off
  (`server.auth.allowUnauthenticatedUsers: true`). Harden for anything beyond a dev preview.

See `values.yaml` for the full set of knobs.
