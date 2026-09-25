{{- define "rag-sync.labels" -}}
app.kubernetes.io/name: rag-sync
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "rag-sync.validateSourceId" -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$" .id) -}}
{{- fail (printf "source id %q must match DNS-1123 label format: ^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$" .id) -}}
{{- end -}}
{{- end }}

{{- define "rag-sync.sourceJson" -}}
{{- include "rag-sync.validateSourceId" . -}}
{{- dict "id" .id "bucket" .bucket "prefix" (.prefix | default "") "extensions" (.extensions | default list) "mirror_deletes" (.mirrorDeletes | default false) | toJson -}}
{{- end }}

{{- define "rag-sync.contentHash" -}}
{{- $root := .root -}}{{- $s := .src -}}
{{- $sourceJson := include "rag-sync.sourceJson" $s -}}
{{- $content := printf "%s%s:%s%s" $sourceJson $root.Values.image.repository $root.Values.image.tag $root.Values.ragApiUrl -}}
{{- $hash := $content | sha256sum -}}
{{- $hash | trunc 8 -}}
{{- end }}

{{- define "rag-sync.podSpec" -}}
{{- $root := .root -}}{{- $s := .src -}}
serviceAccountName: {{ $root.Values.existingServiceAccount | default (printf "%s-src-%s" $root.Release.Name $s.id) }}
restartPolicy: Never
{{- with $root.Values.nodeSelector }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.tolerations }}
tolerations: {{- toYaml . | nindent 2 }}
{{- end }}
containers:
  - name: sync
    image: "{{ $root.Values.image.repository }}:{{ $root.Values.image.tag }}"
    imagePullPolicy: {{ $root.Values.image.pullPolicy }}
    command: ["python", "-m", "rag_api.sync"]
    env:
      - name: SOURCE_JSON
        value: {{ include "rag-sync.sourceJson" $s | quote }}
      - name: RAG_API_URL
        value: {{ required "ragApiUrl is required" $root.Values.ragApiUrl | quote }}
      - name: AWS_REGION
        value: {{ $root.Values.awsRegion | quote }}
      - name: SERVICE_TOKEN
        valueFrom:
          secretKeyRef:
            name: {{ required "serviceTokenSecret.name is required" $root.Values.serviceTokenSecret.name }}
            key: {{ $root.Values.serviceTokenSecret.key }}
    resources: {{- toYaml $root.Values.resources | nindent 6 }}
{{- end }}
