#!/usr/bin/env bash
# Install the Amortized RHOAI tier. Cluster-admin required.
#
#   ./install.sh [gateway-namespace] [extra helm args for the umbrella...]
#
# Two releases:
#   1. openshell-platform  -> the OpenShell namespace (shared cluster infra: agent-sandbox
#      CRD + gateway + privileged SCC). The two `--set ...=null` flags clear the NVIDIA
#      subchart's securityContext so the restricted-v2 SCC injects a uid (Helm ignores
#      file-level nulls, so they must come from the CLI).
#   2. amortized-rhoai     -> the gateway namespace (studio-gateway + nav registration +
#      the openshell-client-tls copy hook, pointed at the OpenShell namespace).
#
# Set OPENSHELL_NS to change the OpenShell namespace (default: openshell). Skip step 1
# by setting SKIP_OPENSHELL=1 if OpenShell is already installed.
#
# A read-only pre-flight gate (preflight.sh, same directory) runs FIRST and aborts if a
# required privilege/prerequisite is missing, so a bad env never half-applies. Bypass with
# SKIP_PREFLIGHT=1; point PREFLIGHT=/path/to/checker at a custom one.
#
# The enterprise MLflow tracking URI is auto-discovered from the operator MLflow Service
# (app=mlflow,component=mlflow). Override by passing --set studio-gateway.mlflow.trackingUri=...
set -euo pipefail
GATEWAY_NS="${1:-amortized-gateway}"
shift || true
OPENSHELL_NS="${OPENSHELL_NS:-openshell}"
CHART_DIR="$(cd "$(dirname "$0")" && pwd)"
HELM_DIR="$(cd "$CHART_DIR/.." && pwd)"   # the helm/ dir holding the sibling charts

# --- Pre-flight gate --------------------------------------------------------------
# Fail fast: run the read-only checker before any cluster change so we never half-apply a
# stack the caller lacks the privileges/prerequisites for. Bypass with SKIP_PREFLIGHT=1.
if [ "${SKIP_PREFLIGHT:-0}" != "1" ]; then
  PREFLIGHT="${PREFLIGHT:-$CHART_DIR/preflight.sh}"
  if [ -f "$PREFLIGHT" ]; then
    # Mirror any --set overrides the install will use into the checker so the gate tests
    # the same targets (plain env-var overrides are inherited by the subshell already).
    MLFLOW_OVERRIDE="${MLFLOW_TRACKING_URI:-}"; DASH_NS_OVERRIDE=""; DASH_DEP_OVERRIDE=""
    for a in "$@"; do
      case "$a" in
        *studio-gateway.mlflow.trackingUri=*)    MLFLOW_OVERRIDE="${a#*studio-gateway.mlflow.trackingUri=}";;
        *navRegistration.dashboard.namespace=*)  DASH_NS_OVERRIDE="${a#*navRegistration.dashboard.namespace=}";;
        *navRegistration.dashboard.deployment=*) DASH_DEP_OVERRIDE="${a#*navRegistration.dashboard.deployment=}";;
      esac
    done
    echo ">> [pre-flight] read-only prerequisite checks (SKIP_PREFLIGHT=1 to bypass)"
    if ! (
      export OPENSHELL_NS SKIP_OPENSHELL="${SKIP_OPENSHELL:-0}"
      if [ -n "$MLFLOW_OVERRIDE" ];   then export MLFLOW_TRACKING_URI="$MLFLOW_OVERRIDE"; fi
      if [ -n "$DASH_NS_OVERRIDE" ];  then export DASHBOARD_NS="$DASH_NS_OVERRIDE"; fi
      if [ -n "$DASH_DEP_OVERRIDE" ]; then export DASHBOARD_DEPLOY="$DASH_DEP_OVERRIDE"; fi
      bash "$PREFLIGHT" "$GATEWAY_NS"
    ); then
      echo >&2 ">> pre-flight FAILED — aborting before any changes. Fix the items above,"
      echo >&2 ">> or re-run with SKIP_PREFLIGHT=1 to bypass."
      exit 1
    fi
    echo
  else
    echo ">> [pre-flight] $PREFLIGHT not found — skipping gate (set SKIP_PREFLIGHT=1 to silence)" >&2
  fi
fi

if [ "${SKIP_OPENSHELL:-0}" != "1" ]; then
  echo ">> [1/2] OpenShell platform -> namespace '$OPENSHELL_NS'"
  helm dependency build "$HELM_DIR/openshell-platform"
  helm upgrade --install openshell-platform "$HELM_DIR/openshell-platform" \
    --namespace "$OPENSHELL_NS" --create-namespace \
    --set 'openshell.podSecurityContext.fsGroup=null' \
    --set 'openshell.securityContext.runAsUser=null'
else
  echo ">> [1/2] SKIP_OPENSHELL=1 — assuming OpenShell already installed in '$OPENSHELL_NS'"
fi

echo ">> [2/2] Amortized RHOAI tier -> namespace '$GATEWAY_NS'"

# Auto-discover the operator MLflow (enterprise mode) unless the caller passed it.
MLFLOW_ARGS=()
if ! printf '%s ' "$@" | grep -q 'studio-gateway.mlflow.trackingUri'; then
  read -r MNS MNAME MPORT <<< "$(oc get svc -A -l app=mlflow,component=mlflow \
    -o jsonpath='{.items[0].metadata.namespace} {.items[0].metadata.name} {.items[0].spec.ports[0].port}' 2>/dev/null || true)"
  if [ -n "${MNAME:-}" ]; then
    MLFLOW="https://$MNAME.$MNS.svc:$MPORT"
    echo ">> discovered operator MLflow: $MLFLOW"
    MLFLOW_ARGS=(--set "studio-gateway.mlflow.trackingUri=$MLFLOW/mlflow" \
                 --set "studio-gateway.mlflow.upstream=$MLFLOW")
  else
    echo ">> WARNING: no operator MLflow Service (app=mlflow,component=mlflow) found — enterprise"
    echo ">>          mode needs it. Pass --set studio-gateway.mlflow.trackingUri=... or run where"
    echo ">>          RHOAI MLflow lives."
  fi
fi

helm dependency build "$CHART_DIR"
helm upgrade --install amortized-rhoai "$CHART_DIR" \
  --namespace "$GATEWAY_NS" --create-namespace \
  --set openshellClientTls.sourceNamespace="$OPENSHELL_NS" \
  ${MLFLOW_ARGS[@]+"${MLFLOW_ARGS[@]}"} \
  "$@"

echo
echo "Installed. The Studio nav item appears once the RHOAI dashboard finishes rolling out"
echo "the updated MODULE_FEDERATION_CONFIG (~2-5 min); refresh the dashboard to see it. Watch:"
echo "  oc rollout status deploy/rhods-dashboard -n redhat-ods-applications"
echo
echo "The embedded-nav registration sets the dashboard operator to Ready=False while the"
echo "plugin is registered (expected; restored on 'helm uninstall amortized-rhoai')."
