#!/usr/bin/env bash
# Pre-flight checks for the Amortized RHOAI tier (install.sh). READ-ONLY: this runs only
# `oc auth can-i`, `oc get`, `helm show` and `oc image info` — it creates and changes
# nothing. Run it after `oc login` to see which privileges or prerequisites are missing
# BEFORE install.sh half-applies.
#
#   ./preflight.sh [gateway-namespace]
#
# Mirrors install.sh knobs:
#   arg 1        gateway namespace          (default: amortized-gateway)
#   OPENSHELL_NS OpenShell namespace        (default: openshell)
#   SKIP_OPENSHELL=1   OpenShell already installed — skip its cluster-scoped checks and
#                      instead verify the client-tls secret is present.
#   MLFLOW_TRACKING_URI=...   skip the operator-MLflow discovery check (matches passing
#                      --set studio-gateway.mlflow.trackingUri to install.sh).
#   DASHBOARD_NS / DASHBOARD_DEPLOY   override the dashboard target (ODH: opendatahub /
#                      odh-dashboard). Defaults: redhat-ods-applications / rhods-dashboard.
#
# Exit 0 if every REQUIRED check passes, 1 if any required check fails. Warnings never
# fail the run (they flag things whose real test happens in-cluster). Safe as a CI gate.
set -uo pipefail   # deliberately NOT -e: run every check, then summarize.

GATEWAY_NS="${1:-amortized-gateway}"
OPENSHELL_NS="${OPENSHELL_NS:-openshell}"
DASHBOARD_NS="${DASHBOARD_NS:-redhat-ods-applications}"
DASHBOARD_DEPLOY="${DASHBOARD_DEPLOY:-rhods-dashboard}"
TLS_SECRET="${TLS_SECRET:-openshell-client-tls}"
CHART_REPO="${CHART_REPO:-oci://ghcr.io/amortized-ai/charts/amortized}"
CHART_VERSION="${CHART_VERSION:-0.2.0}"
# Default tags track values.yaml (studio-gateway.image.tag / pluginFrontend.image.tag).
GATEWAY_IMAGE="${GATEWAY_IMAGE:-ghcr.io/amortized-ai/studio-gateway:latest}"
PLUGIN_IMAGE="${PLUGIN_IMAGE:-ghcr.io/amortized-ai/amortized-studio:latest}"

if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; Z=$'\e[0m'; else R=; G=; Y=; B=; Z=; fi
pass=0; warn=0; fail=0
ok()   { printf '  %s[ OK ]%s %s\n'  "$G" "$Z" "$1"; pass=$((pass+1)); }
bad()  { printf '  %s[FAIL]%s %s\n'  "$R" "$Z" "$1"; fail=$((fail+1)); }
note() { printf '  %s[WARN]%s %s\n'  "$Y" "$Z" "$1"; warn=$((warn+1)); }
info() { printf '  %s-%s     %s\n'   "$B" "$Z" "$1"; }
sec()  { printf '\n%s== %s ==%s\n'   "$B" "$1" "$Z"; }

# cani <req|opt> "<label>" <verb> <resource> [extra oc args...]  — read-only auth check.
cani() {
  local level="$1" label="$2" verb="$3" res="$4"; shift 4
  if oc auth can-i "$verb" "$res" "$@" >/dev/null 2>&1; then
    ok "$label"
  elif [ "$level" = req ]; then
    bad "$label  ->  oc auth can-i $verb $res $*"
  else
    note "$label  ->  oc auth can-i $verb $res $*"
  fi
}

sec "tooling & login"
if command -v oc  >/dev/null 2>&1; then ok "oc found ($(oc version --client -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -1))"; else bad "oc not found in PATH"; fi
if command -v helm >/dev/null 2>&1; then
  hv="$(helm version --short 2>/dev/null)"; hmaj="$(printf '%s' "$hv" | sed -E 's/^v//; s/\..*//')"
  if [ "${hmaj:-0}" -ge 3 ] 2>/dev/null; then ok "helm found ($hv)"; else note "helm found but version looks old ($hv) — need v3+"; fi
else bad "helm not found in PATH"; fi
if who="$(oc whoami 2>/dev/null)"; then info "logged in as $who @ $(oc whoami --show-server 2>/dev/null)"; else bad "not logged in — run: oc login ..."; fi

# Blunt cluster-admin signal (informational). If yes, every required check below is covered.
if oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then
  info "cluster-admin: ${G}yes${Z} (covers all required privileges below)"
else
  info "cluster-admin: no — the per-resource checks below show exactly what is missing"
fi

sec "cluster-scoped privileges"
if [ "${SKIP_OPENSHELL:-0}" = 1 ]; then
  info "SKIP_OPENSHELL=1 — OpenShell assumed installed; its CRD/SCC/cluster-RBAC creates not needed by this run"
else
  cani req "create CustomResourceDefinitions (openshell sandbox CRD)" create customresourcedefinitions.apiextensions.k8s.io
  cani req "create SecurityContextConstraints (openshell privileged SCC)" create securitycontextconstraints.security.openshift.io
  cani req "create ClusterRoles (agent-sandbox + gateway per-user RBAC)" create clusterroles.rbac.authorization.k8s.io
  cani req "create ClusterRoleBindings" create clusterrolebindings.rbac.authorization.k8s.io
fi
cani req "create Namespaces (openshell + $GATEWAY_NS + runtime amz-*)" create namespaces

sec "dashboard namespace: $DASHBOARD_NS (nav registration)"
if oc get deploy "$DASHBOARD_DEPLOY" -n "$DASHBOARD_NS" >/dev/null 2>&1; then
  ok "dashboard deployment $DASHBOARD_DEPLOY exists"
else
  bad "dashboard deployment $DASHBOARD_DEPLOY not found in $DASHBOARD_NS (ODH? set DASHBOARD_NS=opendatahub DASHBOARD_DEPLOY=odh-dashboard)"
fi
cani req "get/patch/update deploy/$DASHBOARD_DEPLOY (set MODULE_FEDERATION_CONFIG)" update deployments.apps -n "$DASHBOARD_NS"
cani req "create Roles in $DASHBOARD_NS (nav-reg SA Role)" create roles.rbac.authorization.k8s.io -n "$DASHBOARD_NS"
cani req "create RoleBindings in $DASHBOARD_NS" create rolebindings.rbac.authorization.k8s.io -n "$DASHBOARD_NS"

sec "gateway namespace: $GATEWAY_NS (release resources)"
for r in serviceaccounts:core secrets:core configmaps:core services:core \
         deployments.apps:apps jobs.batch:batch \
         roles.rbac.authorization.k8s.io:rbac rolebindings.rbac.authorization.k8s.io:rbac \
         routes.route.openshift.io:route; do
  res="${r%%:*}"; kind="${r##*:}"
  cani req "create ${res%%.*} ($kind) in $GATEWAY_NS" create "$res" -n "$GATEWAY_NS"
done

sec "openshell namespace: $OPENSHELL_NS (client-tls copy hook)"
if [ "${SKIP_OPENSHELL:-0}" = 1 ]; then
  if oc get secret "$TLS_SECRET" -n "$OPENSHELL_NS" >/dev/null 2>&1; then
    ok "client-tls secret $TLS_SECRET present in $OPENSHELL_NS"
  else
    bad "SKIP_OPENSHELL=1 but secret $TLS_SECRET not found in $OPENSHELL_NS — OpenShell not installed there?"
  fi
fi
cani req "get Secrets in $OPENSHELL_NS (read client-tls source)" get secrets -n "$OPENSHELL_NS"
cani req "create Roles/RoleBindings in $OPENSHELL_NS" create roles.rbac.authorization.k8s.io -n "$OPENSHELL_NS"
if ! oc get ns "$OPENSHELL_NS" >/dev/null 2>&1; then
  info "$OPENSHELL_NS does not exist yet (install creates it); the checks above assume cluster-scoped grants"
fi

sec "prerequisite: enterprise MLflow (install.sh auto-discovers app=mlflow,component=mlflow)"
if [ -n "${MLFLOW_TRACKING_URI:-}" ]; then
  ok "MLFLOW_TRACKING_URI override set — discovery skipped ($MLFLOW_TRACKING_URI)"
else
  mls="$(oc get svc -A -l app=mlflow,component=mlflow \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.spec.ports[0].port}{"\n"}{end}' 2>/dev/null)"
  n="$(printf '%s\n' "$mls" | grep -c .)"
  if   [ "$n" -eq 1 ]; then ok  "operator MLflow discovered: $mls"
  elif [ "$n" -eq 0 ]; then bad "no MLflow Service (app=mlflow,component=mlflow) — pass --set studio-gateway.mlflow.trackingUri=... or install where RHOAI MLflow lives"
  else                      note "$n MLflow Services match; install.sh uses the first:"$'\n'"$(printf '%s' "$mls" | sed 's/^/         /')"
  fi
fi

sec "prerequisite: images & chart are public/reachable (advisory — real pull is in-cluster)"
if helm show chart "$CHART_REPO" --version "$CHART_VERSION" >/dev/null 2>&1; then
  ok "core chart pullable: $CHART_REPO:$CHART_VERSION"
else
  note "could not pull $CHART_REPO:$CHART_VERSION from here (laptop egress?) — the gateway pulls it in-cluster at provision time"
fi
for img in "$GATEWAY_IMAGE" "$PLUGIN_IMAGE"; do
  if oc image info "$img" --filter-by-os linux/amd64 >/dev/null 2>&1; then
    ok "image pullable: $img"
  else
    note "could not inspect $img from here — pulled in-cluster (imagePullPolicy: Always)"
  fi
done

sec "summary"
printf '  passed %s%d%s   warnings %s%d%s   failed %s%d%s\n' "$G" "$pass" "$Z" "$Y" "$warn" "$Z" "$R" "$fail" "$Z"
if [ "$fail" -gt 0 ]; then
  printf '%s  NOT READY — %d required check(s) failed; fix them before running install.sh.%s\n' "$R" "$fail" "$Z"
  exit 1
fi
printf '%s  READY — all required checks passed.%s' "$G" "$Z"
[ "$warn" -gt 0 ] && printf ' (%d advisory warning(s) above)' "$warn"
printf '\n'
exit 0
