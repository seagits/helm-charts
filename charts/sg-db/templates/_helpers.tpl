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
{{- if not .Values.backup.bucket -}}
{{- fail "backup.bucket is required (the stack's managed backup bucket)" -}}
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

{{/*
One backup Pod. .mode: nightly | first | final.
dump (database image) writes /work/dump.sql.gz and /work/rc ("0", "skipped", or the dump's exit code);
upload (aws-cli image) uploads, prunes, writes backups/_status.json, and sets the exit code.
*/}}
{{- define "sg-db.backupPod" -}}
{{- $root := .root -}}
serviceAccountName: {{ include "sg-db.saName" $root }}
restartPolicy: Never
volumes:
  - name: work
    emptyDir: {}
  - name: scripts
    configMap: { name: {{ $root.Release.Name }}-backup-scripts, defaultMode: 0555 }
initContainers:
  - name: dump
    image: {{ include "sg-db.image" $root | quote }}
    command: ["/bin/bash", "/scripts/dump.sh"]
    env:
      - { name: ENGINE, value: {{ $root.Values.engine | quote }} }
      - { name: DB_HOST, value: {{ printf "%s.%s.svc.cluster.local" $root.Release.Name $root.Release.Namespace | quote }} }
      - { name: DB_NAME, value: {{ $root.Values.database.name | quote }} }
      - name: ADMIN_PASSWORD
        valueFrom: { secretKeyRef: { name: {{ $root.Release.Name }}-auth, key: ADMIN_PASSWORD } }
    volumeMounts:
      - { name: work, mountPath: /work }
      - { name: scripts, mountPath: /scripts }
containers:
  - name: upload
    image: {{ $root.Values.images.awscli | quote }}
    command: ["/bin/bash", "/scripts/upload.sh"]
    env:
      - name: MODE
        value: {{ .mode | quote }}
      - { name: BUCKET, value: {{ $root.Values.backup.bucket | quote }} }
      - { name: AWS_REGION, value: {{ $root.Values.backup.region | quote }} }
      - { name: PREFIX, value: {{ $root.Values.backup.prefix | quote }} }
      - { name: RETENTION_DAYS, value: {{ $root.Values.backup.retentionDays | quote }} }
      {{- with $root.Values.backup.endpointUrl }}
      - { name: AWS_ENDPOINT_URL, value: {{ . | quote }} }
      {{- end }}
    {{- with $root.Values.backup.extraEnvFromSecret }}
    envFrom:
      - secretRef: { name: {{ . }} }
    {{- end }}
    volumeMounts:
      - { name: work, mountPath: /work }
      - { name: scripts, mountPath: /scripts }
{{- end }}
