# amortized-deploy

Install [**Amortized**](https://github.com/amortized-ai/amortized) on your own
**Red Hat OpenShift AI (RHOAI)** / OpenShift cluster.

Amortized surfaces **Studio** as an embedded nav item in the RHOAI dashboard, backed by
**per-user provisioning**: on first hit each dashboard user gets an isolated backend (the
core Amortized app, pulled from OCI at runtime) and an OpenShell-sandboxed **Morty** chat
agent. This repo is the Helm layer that wires that onto a cluster.

> The core Amortized app chart is published separately at
> `oci://ghcr.io/amortized-ai/charts/amortized` and is installable on its own for
> non-RHOAI users — nothing here is required for that path.

## Quick start

Cluster-admin, `oc` (logged in) and `helm` v3+ required.

```bash
git clone https://github.com/amortized-ai/amortized-deploy.git
cd amortized-deploy/helm/amortized-rhoai
./install.sh amortized-gateway
```

`install.sh` runs a read-only pre-flight gate, installs the OpenShell platform, then the
Amortized RHOAI tier into the namespace you pass (default `amortized-gateway`). It
auto-discovers the RHOAI operator MLflow. See
[`helm/amortized-rhoai/README.md`](helm/amortized-rhoai/README.md) for prerequisites, the
full cluster-admin RBAC breakdown, model-provider setup, and uninstall.

> **Using Vertex for Morty chat?** The GCP project is baked into the gateway at install
> time, so pass it now — OpenAI/Anthropic keys, by contrast, are added later in the Studio
> UI and need no install flag:
>
> ```bash
> ./install.sh amortized-gateway --set studio-gateway.morty.googleCloudProject=<your-gcp-project>
> ```
>
> `VERTEX_LOCATION` defaults to `global`; override with
> `--set studio-gateway.morty.vertexLocation=<region>`.

## Latest vs pinned installs

**By default `install.sh` tracks _latest_** — the newest images and core chart from `main`.
Convenient, but it **can be unstable**: it moves as PRs merge, and pods re-pull `:latest` on
restart, so an install can drift from under you.

**For anything you need to reproduce or reason about** — demos, customer POCs, SSA testing —
install a **pinned release** instead: a values file that locks every image **and** the core
chart to one validated set of shas, so restarts and re-installs are byte-identical.

| Install | Command (from `helm/amortized-rhoai`) | Use when |
|---------|----------------------------------------|----------|
| **Latest** — may be unstable | `./install.sh amortized-gateway` | newest build / quick look / dev |
| **Pinned** — reproducible | `./install.sh amortized-gateway -f releases/<release>.yaml` | stability: demos, POCs, bug reports |

Available pinned releases live in
[`helm/amortized-rhoai/releases/`](helm/amortized-rhoai/releases/).

## What's in here

| Chart | Purpose |
|-------|---------|
| [`helm/amortized-rhoai`](helm/amortized-rhoai/README.md) | Umbrella: the RHOAI tier — `studio-gateway` subchart + dashboard nav registration + OpenShell mTLS cert copy. Start here (`install.sh`). |
| [`helm/studio-gateway`](helm/studio-gateway/README.md) | The shared-tier gateway: oauth-proxy + embedded Studio + the per-user provisioner. |
| [`helm/openshell-platform`](helm/openshell-platform/README.md) | Cluster prerequisite: the agent-sandbox controller + OpenShell gateway + privileged SCC for sandboxed Morty. |

## Uninstall

```bash
cd helm/amortized-rhoai
./uninstall.sh amortized-gateway
```

Removes only what the install creates and preserves the enterprise MLflow and other users'
backends. Details in the [chart README](helm/amortized-rhoai/README.md#uninstall).
