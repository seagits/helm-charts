{{- define "sg-db.selectorLabels" -}}
app.kubernetes.io/name: sg-db
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "sg-db.labels" -}}
{{ include "sg-db.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
sg-db/engine: {{ .Values.engine }}
{{- end }}

{{- define "sg-db.validate" -}}
{{- if not (has .Values.engine (list "postgres" "mysql")) -}}
{{- fail (printf "engine must be postgres or mysql, got %q" .Values.engine) -}}
{{- end -}}
{{- if not (has .Values.reach (list "cluster" "vpc")) -}}
{{- fail (printf "reach must be cluster or vpc, got %q" .Values.reach) -}}
{{- end -}}
{{- if or (not .Values.auth.adminPassword) (not .Values.auth.appPassword) -}}
{{- fail "auth.adminPassword and auth.appPassword are required" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]{0,62}$" .Values.database.name) -}}
{{- fail (printf "database.name %q must be a plain identifier" .Values.database.name) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]{0,31}$" .Values.database.user) -}}
{{- fail (printf "database.user %q must be a plain identifier" .Values.database.user) -}}
{{- end -}}
{{- end }}

{{- define "sg-db.port" -}}{{ if eq .Values.engine "postgres" }}5432{{ else }}3306{{ end }}{{- end }}
{{- define "sg-db.image" -}}{{ if eq .Values.engine "postgres" }}{{ .Values.images.postgres }}{{ else }}{{ .Values.images.mysql }}{{ end }}{{- end }}
{{- define "sg-db.adminUser" -}}{{ if eq .Values.engine "postgres" }}postgres{{ else }}root{{ end }}{{- end }}
{{- define "sg-db.saName" -}}{{ default (printf "%s-backup" .Release.Name) .Values.serviceAccount.name }}{{- end }}
