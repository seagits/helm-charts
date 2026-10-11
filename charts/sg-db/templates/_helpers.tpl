{{- define "sg-db.selectorLabels" -}}{{ include "sg-stateful.selectorLabels" . }}{{- end }}

{{- define "sg-db.labels" -}}{{ include "sg-stateful.labels" . }}{{- end }}

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
{{- if not .Values.backup.bucket -}}
{{- fail "backup.bucket is required (the stack's managed backup bucket)" -}}
{{- end -}}
{{- $k := toString .Values.backup.kmsKeyId -}}
{{- if and $k (not (regexMatch "^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$" $k)) -}}
{{- fail "backup.kmsKeyId must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>) or empty" -}}
{{- end -}}
{{- $p := toString .Values.backup.prefix -}}
{{- if or (not (regexMatch "^([A-Za-z0-9!_.'()-]+/)+$" $p)) (regexMatch "(^|/)[.]{1,2}/" $p) -}}
{{- fail "backup.prefix must be a folder such as backups/ — letters, digits and !_.'()- only, ending with /" -}}
{{- end -}}
{{- end }}

{{- define "sg-db.port" -}}{{ if eq .Values.engine "postgres" }}5432{{ else }}3306{{ end }}{{- end }}
{{- define "sg-db.image" -}}{{ if eq .Values.engine "postgres" }}{{ .Values.images.postgres }}{{ else }}{{ .Values.images.mysql }}{{ end }}{{- end }}
{{- define "sg-db.adminUser" -}}{{ if eq .Values.engine "postgres" }}postgres{{ else }}root{{ end }}{{- end }}
{{- define "sg-db.saName" -}}{{ default (printf "%s-backup" .Release.Name) .Values.serviceAccount.name }}{{- end }}

{{/* Arguments for the library's backup templates. */}}
{{- define "sg-db.backupArgs" -}}
dumpImage: {{ include "sg-db.image" . | quote }}
dumpEnv: sg-db.dumpEnv
{{- end }}

{{- define "sg-db.dumpEnv" -}}
- { name: ENGINE, value: {{ .Values.engine | quote }} }
- { name: DB_HOST, value: {{ printf "%s.%s.svc.cluster.local" .Release.Name .Release.Namespace | quote }} }
- { name: DB_NAME, value: {{ .Values.database.name | quote }} }
- name: ADMIN_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ .Release.Name }}-auth, key: ADMIN_PASSWORD } }
{{- end }}

{{- define "sg-db.dumpScript" -}}
#!/bin/bash
# Runs in the database image. Never fails the pod itself: the upload container decides.
set -uo pipefail
out=/work/dump.sql.gz
if [ "$ENGINE" = postgres ]; then
  export PGPASSWORD="$ADMIN_PASSWORD"
  if ! pg_isready -h "$DB_HOST" -p 5432 -t 10 >/dev/null 2>&1; then echo skipped > /work/rc; exit 0; fi
  pg_dump -h "$DB_HOST" -U postgres -d "$DB_NAME" --no-owner --no-privileges 2>/work/err | gzip > "$out"
else
  if ! mysqladmin ping -h "$DB_HOST" -uroot -p"$ADMIN_PASSWORD" --connect-timeout=10 >/dev/null 2>&1; then echo skipped > /work/rc; exit 0; fi
  mysqldump -h "$DB_HOST" -uroot -p"$ADMIN_PASSWORD" --single-transaction --routines --triggers "$DB_NAME" 2>/work/err | gzip > "$out"
fi
echo "$?" > /work/rc
exit 0
{{- end }}
