#!/usr/bin/env bash
# Tear down the Amortized RHOAI tier installed by install.sh. Cluster-admin required.
#
#   ./uninstall.sh [gateway-namespace]
#
# Removes ONLY what install.sh creates:
#   1. the amortized-rhoai umbrella release (its pre-delete hooks de-register the dashboard
#      nav — reverting to the federation-config ConfigMap baseline, operator back to Ready —
#      and delete the copied openshell-client-tls Secret);
#   2. the openshell-platform release + the sandboxes CRD + ns openshell/agent-sandbox-system
#      (via that chart's uninstall.sh, since plain `helm uninstall` leaves the CRD + ns);
#   3. the gateway namespace + every per-user amz-<user>-<hash> namespace (each holds a core
#      `amortized` release);
#   4. orphaned studio-gateway ClusterRoleBindings whose subject namespace no longer exists.
#
# Knobs: OPENSHELL_NS (default: openshell); SKIP_OPENSHELL=1 leaves the shared OpenShell
# platform in place.
#
# PRESERVES (never touched): the operator/enterprise MLflow, ns amortized / amortized-jobs,
# other users' amortized-u-* / *-amortized backends, and all redhat-ods-* resources.
set -uo pipefail   # deliberately NOT -e: best-effort teardown — keep going, then summarize.

GATEWAY_NS="${1:-amortized-gateway}"
OPENSHELL_NS="${OPENSHELL_NS:-openshell}"
CHART_DIR="$(cd "$(dirname "$0")" && pwd)"
HELM_DIR="$(cd "$CHART_DIR/.." && pwd)"   # the helm/ dir holding the sibling charts

echo ">> [1/4] uninstall the amortized-rhoai umbrella (ns '$GATEWAY_NS')"
helm uninstall amortized-rhoai -n "$GATEWAY_NS" 2>/dev/null || echo "   (release not found — skipping)"

if [ "${SKIP_OPENSHELL:-0}" != "1" ]; then
  echo ">> [2/4] uninstall the OpenShell platform (ns '$OPENSHELL_NS')"
  bash "$HELM_DIR/openshell-platform/uninstall.sh" "$OPENSHELL_NS"
else
  echo ">> [2/4] SKIP_OPENSHELL=1 — leaving the shared OpenShell platform in place"
fi

echo ">> [3/4] delete the gateway namespace + every per-user amz-<user> namespace"
# Only amz-<user>-<hash> match ^amz- ; the preserved backends are amortized-* / *-amortized.
amz_ns="$(oc get ns -o name 2>/dev/null | sed 's|namespace/||' | grep -E '^amz-' || true)"
# shellcheck disable=SC2086  # word-splitting is intended (one arg per namespace)
oc delete ns "$GATEWAY_NS" $amz_ns --ignore-not-found

echo ">> [4/4] remove orphaned studio-gateway ClusterRoleBindings (subject namespace gone)"
for crb in $(oc get clusterrolebinding -o name 2>/dev/null | grep -iE 'studio-gateway' || true); do
  sns="$(oc get "$crb" -o jsonpath='{.subjects[0].namespace}' 2>/dev/null || true)"
  if [ -n "$sns" ] && ! oc get ns "$sns" >/dev/null 2>&1; then
    echo "   removing $crb (subject ns '$sns' no longer exists)"
    oc delete "$crb" --ignore-not-found
  fi
done

echo
echo "Done. PRESERVED: operator MLflow, ns amortized/amortized-jobs, amortized-u-*/*-amortized"
echo "backends, and all redhat-ods-* resources."
echo "Verify:  helm list -A  |  oc get ns | grep -E 'amz-|amortized-gateway|openshell'"
