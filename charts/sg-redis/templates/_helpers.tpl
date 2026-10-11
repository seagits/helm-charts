{{- define "sg-redis.validate" -}}
{{- if not (has .Values.engine (list "valkey" "redis")) -}}
{{- fail (printf "engine must be valkey or redis, got %q" .Values.engine) -}}
{{- end -}}
{{- if not (has .Values.reach (list "cluster" "vpc" "public")) -}}
{{- fail (printf "reach must be cluster, vpc or public, got %q" .Values.reach) -}}
{{- end -}}
{{- if not (hasKey .Values.sizes (toString .Values.size)) -}}
{{- fail (printf "size must be one of %s, got %q" (keys .Values.sizes | sortAlpha | join ", ") .Values.size) -}}
{{- end -}}
{{- if not (has .Values.evictionPolicy (list "noeviction" "allkeys-lru" "volatile-lru" "allkeys-lfu" "volatile-lfu" "allkeys-random" "volatile-ttl")) -}}
{{- fail (printf "evictionPolicy %q is not a Redis maxmemory-policy" .Values.evictionPolicy) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_.~-]{16,128}$" (toString .Values.auth.password)) -}}
{{- fail "auth.password is required: 16-128 characters, letters, digits and _.~- only" -}}
{{- end -}}
{{- if not (regexMatch "^[0-9]{1,6}$" (toString .Values.maxclients)) -}}
{{- fail "maxclients must be a number" -}}
{{- end -}}
{{- if eq .Values.reach "public" -}}
{{- if not (regexMatch "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]{2,63}$" (toString .Values.public.leafHost)) -}}
{{- fail "public.leafHost must be a DNS name (the platform fills ${seagit.app.leaf_host}; the component must be publicly exposed with an environment domain)" -}}
{{- end -}}
{{- if and .Values.public.certIssuer (not (regexMatch "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]{2,63}$" (toString .Values.public.host))) -}}
{{- fail "public.host must be a DNS name when public.certIssuer is set (the platform fills ${seagit.app.host})" -}}
{{- end -}}
{{- if not .Values.public.tlsSecret -}}
{{- fail "public.tlsSecret is required for reach=public (the platform fills ${seagit.app.tls_secret})" -}}
{{- end -}}
{{- range (include "sg-redis.cidrs" . | fromJsonArray) -}}
{{- if not (regexMatch "^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])[.]){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])/([0-9]|[12][0-9]|3[0-2])$" .) -}}
{{- fail (printf "public.allowedCidrs: %q is not an IPv4 CIDR such as 203.0.113.7/32" .) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- include "sg-stateful.validateBackup" . -}}
{{- end }}

{{/* The allowlist as a JSON array: comma/space separated, blanks dropped. */}}
{{- define "sg-redis.cidrs" -}}
{{- $out := list -}}
{{- range (regexSplit "[,\\s]+" (toString .Values.public.allowedCidrs) -1) -}}
{{- if . }}{{ $out = append $out . }}{{ end -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{- define "sg-redis.image" -}}{{ if eq .Values.engine "valkey" }}{{ .Values.images.valkey }}{{ else }}{{ .Values.images.redis }}{{ end }}{{- end }}
{{- define "sg-redis.server" -}}{{ .Values.engine }}-server{{- end }}
{{- define "sg-redis.cli" -}}{{ .Values.engine }}-cli{{- end }}
{{- define "sg-redis.size" -}}{{ index .Values.sizes (toString .Values.size) | toJson }}{{- end }}
{{- define "sg-redis.public" -}}{{ eq .Values.reach "public" }}{{- end }}

{{/* Password env for the CLI (valkey-cli reads VALKEYCLI_AUTH, redis-cli REDISCLI_AUTH). */}}
{{- define "sg-redis.cliAuthEnv" -}}
- name: REDISCLI_AUTH
  valueFrom: { secretKeyRef: { name: {{ .Release.Name }}-auth, key: PASSWORD } }
- name: VALKEYCLI_AUTH
  valueFrom: { secretKeyRef: { name: {{ .Release.Name }}-auth, key: PASSWORD } }
{{- end }}

{{/* Arguments for the library's backup templates. */}}
{{- define "sg-redis.backupArgs" -}}
dumpImage: {{ include "sg-redis.image" . | quote }}
dumpEnv: sg-redis.dumpEnv
{{- end }}

{{- define "sg-redis.dumpEnv" -}}
- { name: HOST, value: {{ printf "%s.%s.svc.cluster.local" .Release.Name .Release.Namespace | quote }} }
- { name: CLI, value: {{ include "sg-redis.cli" . | quote }} }
{{ include "sg-redis.cliAuthEnv" . }}
{{- end }}

{{/* RDB snapshot over the replication protocol (--rdb), gzipped. Never fails the pod itself. */}}
{{- define "sg-redis.dumpScript" -}}
#!/bin/bash
# Runs in the Redis image. Never fails the pod itself: the upload container decides.
set -uo pipefail
out=/work/dump.rdb.gz
# A just-started pod's Service endpoint can take a few seconds to route: retry for ~30s.
up=0; for i in 1 2 3 4 5 6; do
  if timeout 5 "$CLI" -h "$HOST" -p 6379 ping 2>/dev/null | grep -q PONG; then up=1; break; fi; sleep 5
done
if [ "$up" != 1 ]; then echo skipped > /work/rc; exit 0; fi
"$CLI" -h "$HOST" -p 6379 --rdb /work/dump.rdb >/dev/null 2>/work/err
rc=$?
if [ "$rc" = 0 ]; then gzip -c /work/dump.rdb > "$out" 2>>/work/err; rc=$?; rm -f /work/dump.rdb; fi
echo "$rc" > /work/rc
exit 0
{{- end }}
