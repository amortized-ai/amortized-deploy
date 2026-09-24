#!/usr/bin/env bash
# Fully uninstall the OpenShell platform for a clean retest.
# `helm uninstall` alone leaves behind: the agent-sandbox CRD (shipped via crds/, which
# Helm never deletes) and the release namespace (created with --create-namespace, which
# Helm does not track). This script removes everything.
set -euo pipefail
NS="${1:-openshell}"

# 1. Delete Sandbox instances first, while the controller is still up to clear finalizers.
oc delete sandboxes.agents.x-k8s.io --all -A --ignore-not-found --wait=true 2>/dev/null || true

# 2. Uninstall the Helm release (gateway, agent-sandbox controller + cluster RBAC,
#    agent-sandbox-system namespace, the SCC RoleBinding).
helm uninstall openshell-platform -n "$NS" 2>/dev/null || true

# 3. Remove the agent-sandbox CRD (crds/ is not removed by helm uninstall).
oc delete crd sandboxes.agents.x-k8s.io --ignore-not-found

# 4. Remove namespaces (openshell was --create-namespace; agent-sandbox-system belt-and-suspenders).
oc delete ns "$NS" agent-sandbox-system --ignore-not-found

echo "OpenShell platform fully removed (release, CRD, ns $NS + agent-sandbox-system)."
