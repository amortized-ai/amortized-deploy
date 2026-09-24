# studio-gateway

The Amortized Studio **gateway** — the RHOAI shared tier. It sits behind oauth-proxy,
authenticates each dashboard user, and on first hit provisions their isolated
`amz-<user>` backend: it installs the amortized **core chart** per user (pulled from
OCI, enterprise-MLflow mode) and creates their **OpenShell-sandboxed Morty**.

Namespace-parameterized: everything installs into the release namespace (`-n <ns>`),
and the cluster-scoped RBAC is named from the release, so multiple installs coexist.

## Prerequisites

- **openshell-platform** installed on the cluster (the `helm/openshell-platform` chart, "E1").
- The **operator MLflow** (RHOAI) reachable, exposing the `mlflow-operator-mlflow-{view,edit}` ClusterRoles.
- Secrets present **in the release namespace**:
  - `openshell-client-tls` — the OpenShell gateway mTLS client cert (copy from the openshell install).
  - `morty-adc` — Vertex ADC JSON (for `modelProvider: vertex`; the volume is optional).
    For `openai`/`anthropic`, instead set `morty.keySecret` to a secret holding `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`.
  - The oauth-proxy cookie secret is **auto-generated** by the chart (and preserved across upgrades).
  - The reencrypt serving cert (`<release>-tls`) is auto-issued by the OpenShift service-ca operator.

## Install

```bash
helm install amortized-gateway helm/studio-gateway -n <namespace> \
  --set chart.version=<core-amortized-chart-version> \
  --set mlflow.trackingUri=https://mlflow.redhat-ods-applications.svc:8443/mlflow \
  --set mlflow.upstream=https://mlflow.redhat-ods-applications.svc:8443 \
  --set morty.googleCloudProject=<gcp-project>
```

Or use the worked example: `-f helm/studio-gateway/values-example.yaml`.

`chart.version` is **required** (the core chart version the gateway installs per user);
rendering fails if it's empty. The gateway image and the core chart version move
independently — bump `chart.version` to roll the per-user stack without rebuilding the image.

## What it deploys

ServiceAccount + cluster-scoped RBAC (auth-delegator, the per-user provisioner role,
and cluster-wide MLflow view/edit for the `/mlflow` proxy), the gateway Deployment
(oauth-proxy + gateway), the public (8443) and http (8080) Services, and the Route.

See `values.yaml` for the full set of knobs.
