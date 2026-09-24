#!/usr/bin/env bash
# Install the OpenShell platform (agent-sandbox + gateway + privileged SCC) as one release.
# The --set null flags are REQUIRED on OpenShift: the gateway subchart hardcodes
# fsGroup/runAsUser=1000, and Helm's subchart value-merge ignores a file-level `null`,
# so they must be cleared via --set for the restricted-v2 SCC to inject a valid uid.
set -euo pipefail
NS="${1:-openshell}"
CHART_DIR="$(cd "$(dirname "$0")" && pwd)"

helm dependency build "$CHART_DIR"
helm upgrade --install openshell-platform "$CHART_DIR" \
  --namespace "$NS" --create-namespace \
  --set openshell.podSecurityContext.fsGroup=null \
  --set openshell.securityContext.runAsUser=null

echo "Installed. Verify: oc get pods -n agent-sandbox-system; oc get pods -n $NS"
