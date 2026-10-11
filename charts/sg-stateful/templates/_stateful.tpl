{{/*
sg-stateful: shared parts of Seagit's single-instance data charts (sg-db, sg-redis).

Contract — a chart that uses this library has these values (same meaning in every chart):
  engine, reach (cluster | vpc | …), avoidSpot, priorityClassName, seagit.deploymentId,
  serviceAccount.{name,roleArn}, images.awscli, backup.{bucket,region,prefix,kmsKeyId,schedule,
  retentionDays,onDelete,firstBackup,activeDeadlineSeconds,hookDeadlineSeconds,endpointUrl,
  extraEnvFromSecret}
and a Secret named <release>-auth. Labels use the parent chart's name (.Chart.Name), so a chart's
rendered output is the same as when these templates lived in it (sg-db compat_test.sh).
*/}}

{{- define "sg-stateful.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "sg-stateful.labels" -}}
{{ include "sg-stateful.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ .Chart.Name }}/engine: {{ .Values.engine }}
{{- end }}

{{- define "sg-stateful.saName" -}}{{ default (printf "%s-backup" .Release.Name) .Values.serviceAccount.name }}{{- end }}

{{/* Keep the data off spot nodes: it is a zonal EBS volume (2026-09-27 qdrant incident). */}}
{{- define "sg-stateful.spotAffinity" -}}
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node.kubernetes.io/lifecycle
              operator: NotIn
              values: [spot]
{{- end }}

{{/* Backup destination checks, shared by every chart's validate. */}}
{{- define "sg-stateful.validateBackup" -}}
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

{{/* ServiceAccount for the backup Pods (IRSA role from the platform). */}}
{{- define "sg-stateful.serviceAccount" -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "sg-stateful.saName" . }}
  labels: {{- include "sg-stateful.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.roleArn }}
  annotations:
    eks.amazonaws.com/role-arn: {{ . }}
  {{- end }}
{{- end }}

{{/* In-cluster Service. dict: root, port, portName */}}
{{- define "sg-stateful.serviceCluster" -}}
{{- $root := .root -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ $root.Release.Name }}
  labels: {{- include "sg-stateful.labels" $root | nindent 4 }}
spec:
  type: ClusterIP
  selector: {{- include "sg-stateful.selectorLabels" $root | nindent 4 }}
  ports:
    - name: {{ .portName }}
      port: {{ .port }}
      targetPort: {{ .portName }}
{{- end }}

{{/*
reach=vpc: an internal NLB (never internet-facing). The platform records its hostname on the
deployment (seagit.io/report-address). dict: root, port, portName
*/}}
{{- define "sg-stateful.serviceVpc" -}}
{{- $root := .root -}}
{{- if eq $root.Values.reach "vpc" }}
apiVersion: v1
kind: Service
metadata:
  name: {{ $root.Release.Name }}-vpc
  labels:
    {{- include "sg-stateful.labels" $root | nindent 4 }}
    seagit.io/report-address: "true"
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
spec:
  type: LoadBalancer
  selector: {{- include "sg-stateful.selectorLabels" $root | nindent 4 }}
  ports:
    - name: {{ .portName }}
      port: {{ .port }}
      targetPort: {{ .portName }}
{{- end }}
{{- end }}

{{/*
The backup scripts ConfigMap. dict: root, dumpScript (name of the chart's template holding dump.sh),
ext (dump file extension, e.g. sql.gz). dump.sh writes /work/dump.<ext> and /work/rc ("0", "skipped",
or the dump's exit code); upload.sh uploads, prunes, writes <prefix>_status.json, sets the exit code.
*/}}
{{- define "sg-stateful.backupScripts" -}}
{{- $root := .root -}}
{{- $ext := .ext -}}
{{- $extRe := replace "." "\\." $ext -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $root.Release.Name }}-backup-scripts
  labels: {{- include "sg-stateful.labels" $root | nindent 4 }}
# No resource-policy annotation needed: Helm runs pre-delete hooks BEFORE it deletes the release's
# resources, so this ConfigMap (and the Secret and ServiceAccount) still exist for the final backup.
data:
  dump.sh: |
    {{- include .dumpScript $root | nindent 4 }}
  upload.sh: |
    #!/bin/bash
    set -uo pipefail
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    # A named KMS key encrypts every upload with it; empty = the bucket's default encryption.
    sse=(); [ -n "${KMS_KEY_ID:-}" ] && sse=(--sse aws:kms --sse-kms-key-id "$KMS_KEY_ID")
    rc=$(cat /work/rc 2>/dev/null || echo missing)
    name="${ts}.{{ $ext }}"; [ "$MODE" = final ] && name="final-${ts}.{{ $ext }}"
    err=$( (tail -c 400 /work/err 2>/dev/null || true) | tr '\n\r\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g')
    status() { # ok skipped object size error
      printf '{"time":"%s","mode":"%s","ok":%s,"skipped":"%s","object":"%s","size":%s,"error":"%s"}\n' \
        "$ts" "$MODE" "$1" "$2" "$3" "$4" "$5" > /tmp/status.json
      aws s3 cp /tmp/status.json "s3://${BUCKET}/${PREFIX}_status.json" ${sse[@]+"${sse[@]}"} --only-show-errors || true
    }
    if [ "$rc" = skipped ]; then
      if [ "$MODE" = nightly ]; then status true "{{ .notRunning }}" "" 0 ""; exit 0; fi
      status false "" "" 0 "{{ .notRunning }} — start the stack first, or use Delete anyway"
      echo "{{ .notRunning }}" >&2; exit 1
    fi
    if [ "$rc" != 0 ]; then status false "" "" 0 "dump failed (rc=$rc): $err"; echo "dump failed: $err" >&2; exit 1; fi
    size=$(stat -c %s /work/dump.{{ $ext }})
    if ! aws s3 cp /work/dump.{{ $ext }} "s3://${BUCKET}/${PREFIX}${name}" ${sse[@]+"${sse[@]}"} --only-show-errors; then
      status false "" "" "$size" "upload failed"; exit 1
    fi
    cutoff=$(date -u -d "-${RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%S)
    # The folder is stripped literally (never used as a regex): only <prefix><ts>.{{ $ext }} is pruned.
    aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX" \
      --query "Contents[?LastModified<'${cutoff}'].Key" --output text 2>/dev/null \
      | tr '\t' '\n' | while read -r k; do
          b=${k#"$PREFIX"}
          if [[ "$k" == "$PREFIX"* && "$b" =~ ^[0-9]{8}T[0-9]{6}Z\.{{ $extRe }}$ ]]; then
            aws s3 rm "s3://${BUCKET}/${k}" --only-show-errors
          fi
        done
    status true "" "${PREFIX}${name}" "$size" ""
    echo "backup ok: s3://${BUCKET}/${PREFIX}${name} (${size} bytes)"
{{- end }}

{{/*
One backup Pod. dict: root, mode (nightly | first | final), dumpImage, dumpEnv (name of the chart's
template holding the dump container's env list).
*/}}
{{- define "sg-stateful.backupPod" -}}
{{- $root := .root -}}
serviceAccountName: {{ include "sg-stateful.saName" $root }}
restartPolicy: Never
volumes:
  - name: work
    emptyDir: {}
  - name: scripts
    configMap: { name: {{ $root.Release.Name }}-backup-scripts, defaultMode: 0555 }
initContainers:
  - name: dump
    image: {{ .dumpImage | quote }}
    command: ["/bin/bash", "/scripts/dump.sh"]
    env:
      {{- include .dumpEnv $root | nindent 6 }}
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
      - { name: KMS_KEY_ID, value: {{ $root.Values.backup.kmsKeyId | quote }} }
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

{{/* Nightly backup CronJob. dict: root, dumpImage, dumpEnv */}}
{{- define "sg-stateful.backupCronJob" -}}
{{- $root := .root -}}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ $root.Release.Name }}-backup
  labels: {{- include "sg-stateful.labels" $root | nindent 4 }}
spec:
  schedule: {{ $root.Values.backup.schedule | quote }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: {{ $root.Values.backup.activeDeadlineSeconds }}
      template:
        spec: {{- include "sg-stateful.backupPod" (merge (dict "mode" "nightly") .) | nindent 10 }}
{{- end }}

{{/*
A backup hook Job. dict: root, dumpImage, dumpEnv, mode (first | final). first = post-install (it is
also what makes the platform deploy the chart through Tier B); final = pre-delete.
*/}}
{{- define "sg-stateful.backupHook" -}}
{{- $root := .root -}}
{{- $on := ternary $root.Values.backup.firstBackup $root.Values.backup.onDelete (eq .mode "first") -}}
{{- if $on }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $root.Release.Name }}-backup-{{ .mode }}
  labels:
    {{- include "sg-stateful.labels" $root | nindent 4 }}
    {{- with $root.Values.seagit.deploymentId }}
    # Owner label: a FAILED hook Job (kept for its logs; hook-delete-policy only removes successes)
    # is deleted by the platform's owner-label destroy cleanup once the stack is deleted.
    seagit.io/deployment: {{ . }}
    {{- end }}
  annotations:
    "helm.sh/hook": {{ ternary "post-install" "pre-delete" (eq .mode "first") }}
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 0
  activeDeadlineSeconds: {{ $root.Values.backup.hookDeadlineSeconds }}
  template:
    spec: {{- include "sg-stateful.backupPod" . | nindent 6 }}
{{- end }}
{{- end }}
