{{- define "ai-manager.name" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 52 | trimSuffix "-" -}}
{{- end -}}
{{- define "ai-manager.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end -}}
{{- define "ai-manager.requirements" -}}
{{- $origin := required "publicOrigin is required" .Values.publicOrigin -}}
{{- if not (regexMatch "^https://[A-Za-z0-9.-]+$" $origin) -}}{{ fail "publicOrigin must be an HTTPS origin without a port, path or trailing slash" }}{{- end -}}
{{- $_ := required "images.backend is required" .Values.images.backend -}}
{{- $_ = required "images.edge is required" .Values.images.edge -}}
{{- if not (regexMatch "^[^[:space:]]+@sha256:[0-9a-f]{64}$" .Values.images.backend) -}}{{ fail "images.backend must be pinned by a full SHA-256 digest" }}{{- end -}}
{{- if not (regexMatch "^[^[:space:]]+@sha256:[0-9a-f]{64}$" .Values.images.edge) -}}{{ fail "images.edge must be pinned by a full SHA-256 digest" }}{{- end -}}
{{- $_ = required "database.jdbcUrl is required" .Values.database.jdbcUrl -}}
{{- $_ = required "database.username is required" .Values.database.username -}}
{{- $_ = required "database.existingSecret is required" .Values.database.existingSecret -}}
{{- $_ = required "signing.existingSecret is required" .Values.signing.existingSecret -}}
{{- $_ = required "identity.serviceName is required" .Values.identity.serviceName -}}
{{- if lt (int .Values.api.replicas) 2 -}}{{ fail "api.replicas must be at least 2 for the availability profile" }}{{- end -}}
{{- if lt (int .Values.edge.replicas) 2 -}}{{ fail "edge.replicas must be at least 2 for the availability profile" }}{{- end -}}
{{- if .Values.ingress.enabled -}}
{{- $_ = required "ingress.host is required" .Values.ingress.host -}}
{{- $_ = required "ingress.tlsSecretName is required" .Values.ingress.tlsSecretName -}}
{{- if ne $origin (printf "https://%s" .Values.ingress.host) -}}{{ fail "publicOrigin must equal https://ingress.host" }}{{- end -}}
{{- end -}}
{{- end -}}
