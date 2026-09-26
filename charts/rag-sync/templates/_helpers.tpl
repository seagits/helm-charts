{{- define "rag-sync.labels" -}}
app.kubernetes.io/name: rag-sync
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "rag-sync.validateSourceId" -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$" .id) -}}
{{- fail (printf "source id %q must match DNS-1123 label format: ^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$" .id) -}}
{{- end -}}
{{- if eq .id "uploads" -}}
{{- fail "source id \"uploads\" is reserved by rag-api for the public upload path; pick another id" -}}
{{- end -}}
{{- end }}

{{/*
A k8s name capped at .max characters. Names that fit are returned unchanged; longer ones are
cut to .max-9 and suffixed with "-" + the first 8 hex of sha256(full name), so user-entered
ids never break a deploy and two long names that share a prefix stay distinct.
Limits: Job 63 (its name becomes the pod label job-name), CronJob 52 (the controller
appends an 11-char suffix to the Jobs it creates).
*/}}
{{- define "rag-sync.fitName" -}}
{{- if le (len .name) (int .max) -}}
{{- .name -}}
{{- else -}}
{{- printf "%s-%s" (trunc (sub (int .max) 9 | int) .name) (.name | sha256sum | trunc 8) -}}
{{- end -}}
{{- end }}

{{- define "rag-sync.sourceJson" -}}
{{- include "rag-sync.validateSourceId" . -}}
{{- dict "id" .id "bucket" .bucket "prefix" (.prefix | default "") "extensions" (.extensions | default list) "mirror_deletes" (.mirrorDeletes | default false) | toJson -}}
{{- end }}

{{/*
The `uploads` SOURCE_JSON: bypasses validateSourceId (the one place "uploads" is allowed) and
always mirrors deletes, since the shared bucket is the sole source of truth for uploaded files.
*/}}
{{- define "rag-sync.uploadsSourceJson" -}}
{{- dict "id" "uploads" "bucket" .Values.uploads.bucket "prefix" (.Values.uploads.prefix | default "uploads/") "extensions" list "mirror_deletes" true | toJson -}}
{{- end }}

{{/*
Job name: <release>-once-<id>-<hash8>, hash8 = sha256 of the rendered pod template. A Job's
pod template is immutable, so any change to it (image, env, SA, region, secret, resources,
securityContext, ...) must yield a new Job name; identical values keep the name stable.
*/}}
{{- define "rag-sync.jobName" -}}
{{- $hash := include "rag-sync.podTemplate" . | sha256sum | trunc 8 -}}
{{- include "rag-sync.fitName" (dict "name" (printf "%s-once-%s-%s" .root.Release.Name .src.id $hash) "max" 63) -}}
{{- end }}

{{- define "rag-sync.cronJobName" -}}
{{- include "rag-sync.fitName" (dict "name" (printf "%s-cron-%s" .root.Release.Name .src.id) "max" 52) -}}
{{- end }}

{{- define "rag-sync.podTemplate" -}}
metadata:
  labels: {{- include "rag-sync.labels" .root | nindent 4 }}
spec: {{- include "rag-sync.podSpec" . | nindent 2 }}
{{- end }}

{{/*
Shared pod/container fields for every rag-sync pod (sync Jobs/CronJobs and the uploads-events
consumer Deployment): serviceAccountName, hardened pod+container securityContext, nodeSelector,
tolerations, image, resources and the /tmp emptyDir. Callers select the workload-specific bits
(restartPolicy, command, env) around this include.
Params: .root, .src (needs .id; used only for the per-source SA name fallback), .restartPolicy
(default "Never").
*/}}
{{- define "rag-sync.podSpec" -}}
{{- $root := .root -}}{{- $s := .src -}}
serviceAccountName: {{ $root.Values.existingServiceAccount | default (printf "%s-src-%s" $root.Release.Name $s.id) }}
restartPolicy: {{ .restartPolicy | default "Never" }}
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  seccompProfile:
    type: RuntimeDefault
{{- with $root.Values.nodeSelector }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.tolerations }}
tolerations: {{- toYaml . | nindent 2 }}
{{- end }}
containers:
  - name: {{ if .events }}events{{ else }}sync{{ end }}
    image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
    imagePullPolicy: {{ $root.Values.image.pullPolicy }}
{{- if .events }}
    command: ["python", "-m", "rag_api.events"]
{{- else }}
    command: ["python", "-m", "rag_api.sync"]
{{- end }}
    env:
{{- if .events }}
      - name: QUEUE_URL
        value: {{ required "uploads.queueUrl is required" $root.Values.uploads.queueUrl | quote }}
{{- else }}
      - name: SOURCE_JSON
        value: {{ if .uploads }}{{ include "rag-sync.uploadsSourceJson" $root | quote }}{{ else }}{{ include "rag-sync.sourceJson" $s | quote }}{{ end }}
{{- end }}
      - name: RAG_API_URL
        value: {{ required "ragApiUrl is required" $root.Values.ragApiUrl | quote }}
      - name: AWS_REGION
        value: {{ $root.Values.awsRegion | quote }}
      - name: SERVICE_TOKEN
        valueFrom:
          secretKeyRef:
            name: {{ required "serviceTokenSecret.name is required" $root.Values.serviceTokenSecret.name }}
            key: {{ $root.Values.serviceTokenSecret.key }}
{{- if .uploads }}
      - name: SYNC_UPLOADS
        value: "1"
{{- end }}
    resources: {{- toYaml $root.Values.resources | nindent 6 }}
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
    volumeMounts:
      - name: tmp
        mountPath: /tmp
volumes:
  # readOnlyRootFilesystem: scratch space for boto3/httpx/tempfile.
  - name: tmp
    emptyDir: {}
{{- end }}
