# amortized-rhoai

The **RHOAI tier** for Amortized — surfaces Studio as an **embedded nav item** in the
RHOAI dashboard, backed by per-user provisioning. Two Helm releases (both via
`install.sh`), because OpenShell is shared cluster infra that belongs in its own namespace:

1. **openshell-platform** → the `openshell` namespace (agent-sandbox CRD + OpenShell
   gateway + privileged SCC). Cluster-admin, once per cluster.
2. **amortized-rhoai** (this chart) → the gateway namespace:
   - **studio-gateway** (subchart) — the shared-tier per-user provisioner (oauth-proxy +
     embedded Studio SPA + `/federated` plugin proxy). On first hit it installs the
     **core app chart per user** from OCI and creates their OpenShell-sandboxed Morty.
   - **openshell-client-tls copy** (hook) — copies the OpenShell mTLS client cert from
     the `openshell` namespace into this release's namespace (a Secret can't be mounted
     cross-namespace). Fully automated — no manual `oc` copy.
   - **nav registration** (hook) — registers `amortizedStudio` in the dashboard's
     `MODULE_FEDERATION_CONFIG`, routed through the gateway.

The per-user core app stack is **pulled from OCI at runtime** by the gateway
(`oci://ghcr.io/amortized-ai/charts/amortized`), not bundled here — so the standalone
core chart stays intact and independently installable by non-RHOAI users:

```bash
# non-RHOAI users, unchanged and unaffected by anything here:
helm install amortized oci://ghcr.io/amortized-ai/charts/amortized
```

## Prerequisites (the cluster-admin facts)

**cluster-admin, once per cluster.** In practice admin is required — the installer creates
cluster-scoped RBAC that grants the gateway its per-user provisioning powers, which K8s
escalation prevention only allows if the installer already holds them. The per-resource
breakdown (useful for a security review) is what that decomposes into:

| Scope | Verbs / resources | Why |
|-------|-------------------|-----|
| Cluster | create `CustomResourceDefinitions` | OpenShell's `sandboxes.agents.x-k8s.io` CRD |
| Cluster | create `SecurityContextConstraints` | OpenShell's privileged SCC for the agent-sandbox |
| Cluster | create `ClusterRoles` + `ClusterRoleBindings` | agent-sandbox controller + gateway per-user provisioning RBAC |
| Cluster | create `Namespaces` | `openshell`, the gateway ns, and runtime `amz-<user>-<hash>` |
| `redhat-ods-applications` | get/patch/update the `rhods-dashboard` Deployment; get the `federation-config` ConfigMap; create `Roles`/`RoleBindings` | nav registration, via a tightly-scoped SA |
| gateway ns | create `ServiceAccounts`, `Secrets`, `ConfigMaps`, `Services`, `Deployments`, `Jobs`, `Roles`, `RoleBindings`, `Routes` | the gateway + plugin + hook resources |
| `openshell` | get `Secrets`; create `Roles`/`RoleBindings` | copy the `openshell-client-tls` cert into the gateway ns |

(Uninstall needs the `delete` equivalents of the cluster-scoped items.)

Also required:

- A running **RHOAI dashboard** (`rhods-dashboard` in `redhat-ods-applications`; for ODH
  set `navRegistration.dashboard.*` to `odh-dashboard` / `opendatahub`).
- The **RHOAI operator MLflow** reachable (enterprise mode) — auto-discovered from the
  `app=mlflow,component=mlflow` Service, or set `studio-gateway.mlflow.*`.
- **Network egress** to pull (in-cluster) the public artifacts: `ghcr.io/amortized-ai/studio-gateway`,
  `ghcr.io/amortized-ai/amortized-studio`, and `oci://ghcr.io/amortized-ai/charts/amortized`.
- **Tooling** on the operator's machine: `oc` (logged in) + `helm` v3+.
- Model-provider creds for Morty in the gateway namespace (Vertex `morty-adc`, or an
  OpenAI/Anthropic key secret) — see `studio-gateway` values.

`openshell-client-tls` is **not** a manual step — the OpenShell install generates it in
the `openshell` namespace and this chart's hook copies it in.

## Pre-flight (check before you install)

`preflight.sh` is **read-only** (`oc auth can-i` / `oc get` / `helm show` only — it changes
nothing). **`install.sh` runs it automatically as a fail-fast gate** and aborts before any
cluster change if a required check fails (bypass with `SKIP_PREFLIGHT=1`). You can also run
it standalone after `oc login`:

```bash
./preflight.sh amortized-gateway
```

It prints a per-resource pass/fail (a non-admin sees exactly which grant is missing and the
`oc auth can-i` to reproduce it), honors the same knobs as `install.sh` (`OPENSHELL_NS`,
`SKIP_OPENSHELL`, `DASHBOARD_NS`/`DASHBOARD_DEPLOY`, `MLFLOW_TRACKING_URI`), and exits
non-zero if any required check fails — so it also works as a CI gate.

## Install

```bash
./install.sh amortized-gateway \
  --set studio-gateway.chart.version=0.2.0 \
  --set studio-gateway.morty.googleCloudProject=<gcp-project>
```

`install.sh` runs both releases (OpenShell into `openshell` with the SCC `--set …=null`
flags, then this chart into the gateway namespace pointed at the OpenShell namespace).
It **auto-discovers the operator MLflow** (the `app=mlflow,component=mlflow` Service) and
wires `mlflow.trackingUri`/`upstream` — override with `--set studio-gateway.mlflow.trackingUri=...`
if your cluster differs; if none is found it warns (enterprise mode needs one).

- OpenShell already installed? `SKIP_OPENSHELL=1 ./install.sh amortized-gateway …`
- Different OpenShell namespace? `OPENSHELL_NS=my-openshell ./install.sh …`

## The embedded-nav caveat (documented for users)

The registration sets `MODULE_FEDERATION_CONFIG` as a literal on the dashboard
Deployment — the SME-sanctioned path today, **but it forces the dashboard operator into
`Ready=False` for as long as the plugin is registered** (it cannot reconcile / heal /
upgrade the dashboard until uninstalled). The pre-delete hook removes the entry and
restores the operator to `Ready=True`. (A future RHOAI release is expected to add a
durable dedicated-ConfigMap path; adopt it when it ships.)

## Uninstall

```bash
./uninstall.sh amortized-gateway
```

The counterpart to `install.sh` — removes **only** what the install creates and **preserves
the enterprise MLflow** and other users' backends. It runs:

1. `helm uninstall amortized-rhoai -n <gateway-ns>` — pre-delete hooks de-register the nav
   (dashboard reverts to the `federation-config` ConfigMap baseline; operator back to
   `Ready=True`) and delete the copied `openshell-client-tls` Secret.
2. `openshell-platform/uninstall.sh <openshell-ns>` — the Sandbox CRs, the `openshell-platform`
   release, the `sandboxes.agents.x-k8s.io` CRD, and ns `<openshell-ns>` + `agent-sandbox-system`.
   (Plain `helm uninstall` leaves the CRD + namespace behind — hence the script.)
3. `oc delete ns <gateway-ns>` and every per-user `amz-<user>-<hash>` namespace (each holds
   a core `amortized` release).
4. Removes orphaned `studio-gateway` ClusterRoleBindings whose subject namespace is gone.

Knobs: `OPENSHELL_NS=…` (default `openshell`); `SKIP_OPENSHELL=1` to leave the shared
OpenShell platform in place.

**Preserved (never touched):** the operator/enterprise MLflow, ns `amortized` /
`amortized-jobs`, other users' `amortized-u-*` / `*-amortized` backends, and all
`redhat-ods-*` resources.

## Known gaps (scaffold TODOs)

- **Plugin frontend is not yet a subchart.** The MF remote bundle (served at
  `/federated`) is a companion deploy today (a reference deployment builds it in-cluster; the
  `oci://quay.io/rh-ai-community-plugins/amortized-studio-chart` ref is not anon-pullable).
  Point `studio-gateway.pluginUpstream` at it, or fold the bundle into the gateway image.
- **Hook images** (`navRegistration.image`, `openshellClientTls.image`) must have `oc`
  + `python3`. Default `quay.io/openshift/origin-cli` is assumed to; override if not.
- **MF-config entry shape** here is the flat `remoteEntry`/`service`/`proxy` form proven
  on RHOAI 3.5. Older dashboards may expect `backend`/`proxyService`; adjust the
  `amortized-rhoai.navEntry` helper if needed.
