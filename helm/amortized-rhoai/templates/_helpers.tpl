{{/* Umbrella base name. */}}
{{- define "amortized-rhoai.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Umbrella fullname (base for this chart's own resource names). Dedupes when the
release name already contains the chart name (avoids amortized-rhoai-amortized-rhoai). */}}
{{- define "amortized-rhoai.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "amortized-rhoai.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "amortized-rhoai.labels" -}}
app.kubernetes.io/name: {{ include "amortized-rhoai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "amortized-rhoai.navServiceAccount" -}}
{{- printf "%s-nav-reg" (include "amortized-rhoai.fullname" .) -}}
{{- end -}}

{{- define "amortized-rhoai.tlsCopyServiceAccount" -}}
{{- printf "%s-tls-copy" (include "amortized-rhoai.fullname" .) -}}
{{- end -}}

{{/*
Gateway fullname — mirrors studio-gateway.fullname so the nav entry points at the
right Service regardless of the release name.
*/}}
{{- define "amortized-rhoai.gatewayFullname" -}}
{{- $sg := (index .Values "studio-gateway") | default dict -}}
{{- if $sg.fullnameOverride -}}
{{- $sg.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := ($sg.nameOverride | default "studio-gateway") -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* The gateway http Service the dashboard proxies the plugin to. */}}
{{- define "amortized-rhoai.gatewayHttpService" -}}
{{- if .Values.navRegistration.gatewayServiceName -}}
{{- .Values.navRegistration.gatewayServiceName -}}
{{- else -}}
{{- printf "%s-http" (include "amortized-rhoai.gatewayFullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
The module-federation entry, in the shape the odh/RHOAI dashboard parses (nested
`backend` + `proxyService`, per rhoai-plugin docs). `backend` -> the plugin frontend
(serves the MF remoteEntry.js); `proxyService` (authorize:true, so the user token is
forwarded for per-user provisioning) -> the gateway, which serves the Studio SPA + api
under the embed base path. Emitted as compact JSON.
*/}}
{{- define "amortized-rhoai.navEntry" -}}
{{- $sg := (index .Values "studio-gateway") | default dict -}}
{{- $embed := ($sg.embedBasePath | default "/amortized-studio-embed") -}}
{{- $gw := include "amortized-rhoai.gatewayHttpService" . -}}
{{- $plugin := .Values.pluginFrontend.serviceName -}}
{{- $pport := (.Values.pluginFrontend.port | default 8080) -}}
{{- $entry := dict
    "name" .Values.navRegistration.moduleName
    "backend" (dict
      "remoteEntry" "/remoteEntry.js"
      "tls" false
      "service" (dict "name" $plugin "namespace" .Release.Namespace "port" (int $pport)))
    "proxyService" (list (dict
      "path" $embed
      "pathRewrite" $embed
      "authorize" true
      "tls" false
      "service" (dict "name" $gw "namespace" .Release.Namespace "port" (int 8080)))) -}}
{{- $entry | toJson -}}
{{- end -}}
