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

{{/*
The per-source object shared by SOURCE_JSON and SOURCES_JSON. `region` / `role_arn` are added only
when non-empty: consumer images older than the bucket-access release build their SourceSpec from
every key and crash on ones they do not know (final review C-I5).
Params: the source fields (.id .bucket .prefix .extensions .mirror_deletes .region .role_arn).
*/}}
{{- define "rag-sync.sourceObj" -}}
{{- $d := dict "id" .id "bucket" .bucket "prefix" .prefix "extensions" .extensions "mirror_deletes" .mirror_deletes -}}
{{- with .region }}{{- $_ := set $d "region" . -}}{{- end -}}
{{- with .role_arn }}{{- $_ := set $d "role_arn" . -}}{{- end -}}
{{- $d | toJson -}}
{{- end }}

{{/* A user source's object (see rag-sync.sourceObj). */}}
{{- define "rag-sync.userSourceObj" -}}
{{- include "rag-sync.sourceObj" (dict "id" .id "bucket" .bucket "prefix" (.prefix | default "") "extensions" (.extensions | default list) "mirror_deletes" (.mirrorDeletes | default false) "region" (.region | default "") "role_arn" (.role_arn | default "")) -}}
{{- end }}

{{/*
The reserved `uploads` source's object: always mirrors deletes (the shared bucket is the sole
source of truth for uploaded files). uploads.region / uploads.role_arn let this cluster read an
existing uploads bucket in another account/region (final review C-C2).
*/}}
{{- define "rag-sync.uploadsSourceObj" -}}
{{- include "rag-sync.sourceObj" (dict "id" "uploads" "bucket" .Values.uploads.bucket "prefix" (.Values.uploads.prefix | default "uploads/") "extensions" list "mirror_deletes" true "region" (.Values.uploads.region | default "") "role_arn" (.Values.uploads.role_arn | default "")) -}}
{{- end }}

{{- define "rag-sync.sourceJson" -}}
{{- include "rag-sync.validateSourceId" . -}}
{{- include "rag-sync.userSourceObj" . -}}
{{- end }}

{{/*
The `uploads` SOURCE_JSON: bypasses validateSourceId (the one place "uploads" is allowed) and
always mirrors deletes, since the shared bucket is the sole source of truth for uploaded files.
*/}}
{{- define "rag-sync.uploadsSourceJson" -}}
{{- include "rag-sync.uploadsSourceObj" . -}}
{{- end }}

{{/*
Per-source sync intent. Two input shapes on a source dict:
  - new-style: source has `sync` and/or `import_now`. `sync` (default "events_sweep" when the
    source is new-style but `sync` itself is absent) is one of
    "none"|"schedule"|"events"|"events_sweep"; `import_now` defaults to true when absent.
  - legacy: neither `sync` nor `import_now` present -> `mode` (default "once", matching 0.2.x's
    `.mode | default "once"`), accepting both this chart's 0.2.x values ("once"|"schedule"|"both")
    and the newer legacy spelling ("once"|"cron"|"once_cron").
Returns dict{import,schedule,events} (all bool), JSON-encoded. Fails fast on an unknown `sync`
value or a source that would never be indexed by anything (no import, no schedule, no events).
Runs validateSourceId so every source is checked here regardless of which workload it renders.
*/}}
{{- define "rag-sync.syncOf" -}}
{{- include "rag-sync.validateSourceId" . -}}
{{- $imp := false -}}{{- $sch := false -}}{{- $evt := false -}}
{{- if or (hasKey . "sync") (hasKey . "import_now") -}}
  {{- $imp = (hasKey . "import_now" | ternary .import_now true) -}}
  {{- $sync := .sync | default "events_sweep" -}}
  {{- $sch = has $sync (list "schedule" "events_sweep") -}}
  {{- $evt = has $sync (list "events" "events_sweep") -}}
  {{- if not (has $sync (list "none" "schedule" "events" "events_sweep")) -}}{{- fail (printf "source %s: unknown sync %q" .id $sync) -}}{{- end -}}
{{- else -}}
  {{- $m := .mode | default "once" -}}
  {{- $imp = has $m (list "once" "once_cron" "both") -}}
  {{- $sch = has $m (list "cron" "once_cron" "schedule" "both") -}}
{{- end -}}
{{- if and (not $imp) (not $sch) (not $evt) -}}{{- fail (printf "source %s would never be indexed: enable import_now or a sync mode" .id) -}}{{- end -}}
{{- dict "import" $imp "schedule" $sch "events" $evt | toJson -}}
{{- end }}

{{/*
The reserved `uploads` slot's sync intent (0.5.0). New-style when uploads.sync is SET (the key
exists): same vocabulary as rag-sync.syncOf; import_now defaults to FALSE (a new stack bucket
starts empty — the template sets it true only for an existing bucket); `none` with a bucket
fails (the template leaves uploads.bucket empty to turn uploads off). Legacy when uploads.sync is
absent: exactly 0.4.0 — no import Job, a CronJob always (safetySchedule when uploads.queueUrl is
set, else uploads.schedule) and uploads always in the events consumer.
Returns dict{new,import,schedule,events,cron} JSON-encoded; only meaningful when uploads.bucket.
*/}}
{{- define "rag-sync.uploadsSyncOf" -}}
{{- $u := .Values.uploads -}}
{{- if hasKey $u "sync" -}}
  {{- $sync := $u.sync | default "events_sweep" -}}
  {{- if not (has $sync (list "none" "schedule" "events" "events_sweep")) -}}{{- fail (printf "uploads: unknown sync %q" $sync) -}}{{- end -}}
  {{/* MINOR d (2026-09-29 rag-uploads-storage-and-sync): `| default false` only substitutes on
       Go's zero value (nil/false/""/0) - a quoted "false" (--set-string, or any string-typed
       source) is a non-empty string and so is TRUTHY here, silently turning import on. Only a
       real true / the string "true" counts as on. */}}
  {{- $imp := eq (toString $u.import_now) "true" -}}
  {{- $sch := has $sync (list "schedule" "events_sweep") -}}
  {{- $evt := has $sync (list "events" "events_sweep") -}}
  {{- if and $u.bucket (not $imp) (not $sch) (not $evt) -}}{{- fail "uploads: sync none with a bucket would never index uploads; leave uploads.bucket empty to turn uploads off" -}}{{- end -}}
  {{- $cron := "" -}}
  {{- if $sch -}}{{- $cron = required "uploads.schedule is required when uploads.sync is schedule or events_sweep" $u.schedule -}}{{- end -}}
  {{- dict "new" true "import" $imp "schedule" $sch "events" $evt "cron" $cron | toJson -}}
{{- else -}}
  {{- $cron := $u.schedule -}}
  {{- if $u.queueUrl -}}{{- $cron = $u.safetySchedule -}}{{- end -}}
  {{- dict "new" false "import" false "schedule" true "events" true "cron" $cron | toJson -}}
{{- end -}}
{{- end }}

{{/*
The events consumer's SOURCES_JSON: a JSON array combining the `uploads` source (when
uploads.bucket is set) with every user source whose rag-sync.syncOf has `events` true. Same
object shape as SOURCE_JSON (rag-sync.sourceObj: id, bucket, prefix, extensions, mirror_deletes,
plus region / role_arn when non-empty) so the consumer parses one schema everywhere.
*/}}
{{- define "rag-sync.eventsSourcesJson" -}}
{{- $list := list -}}
{{- if and .Values.uploads.bucket (include "rag-sync.uploadsSyncOf" . | fromJson).events -}}
{{- $list = append $list (include "rag-sync.uploadsSourceObj" . | fromJson) -}}
{{- end -}}
{{- range .Values.sources -}}
{{- if (include "rag-sync.syncOf" . | fromJson).events -}}
{{- $list = append $list (include "rag-sync.userSourceObj" . | fromJson) -}}
{{- end -}}
{{- end -}}
{{- $list | toJson -}}
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
        value: {{ required "eventsQueueUrl or uploads.queueUrl is required" ($root.Values.eventsQueueUrl | default $root.Values.uploads.queueUrl) | quote }}
      - name: SOURCES_JSON
        value: {{ include "rag-sync.eventsSourcesJson" $root | quote }}
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
