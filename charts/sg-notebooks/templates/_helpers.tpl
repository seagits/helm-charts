{{- define "sg-notebooks.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
The node pool for the chart's own pods (certificate reload, cleanup hook). The hub, proxy and
notebook servers take the same pool from jupyterhub.hub/proxy.chp/singleuser (set by the record).
*/}}
{{- define "sg-notebooks.placement" -}}
{{- with .Values.nodeSelector }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations: {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "sg-notebooks.dnsRe" -}}^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]{2,63}${{- end }}

{{- define "sg-notebooks.csv" -}}
{{- $out := list -}}
{{- range (regexSplit "[,\\s]+" (toString .) -1) -}}
{{- if . }}{{ $out = append $out . }}{{ end -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/*
Everything the record must get right, checked before anything is applied. The upstream chart's
values that duplicate a top-level value (host, leaf, TLS secret) must agree with it: the record
writes both, and a mismatch would serve one name and certify another.
*/}}
{{- define "sg-notebooks.validate" -}}
{{- $dns := include "sg-notebooks.dnsRe" . -}}
{{- $jh := .Values.jupyterhub -}}
{{- $auth := $jh.custom.auth -}}
{{- if not (regexMatch $dns (toString .Values.public.host)) -}}
{{- fail "public.host must be a DNS name (the platform fills ${seagit.app.host}; the hub component must be publicly exposed with an environment domain)" -}}
{{- end -}}
{{- if not (regexMatch $dns (toString .Values.public.leafHost)) -}}
{{- fail "public.leafHost must be a DNS name (the platform fills ${seagit.app.leaf_host})" -}}
{{- end -}}
{{- if not .Values.public.tlsSecret -}}
{{- fail "public.tlsSecret is required (the platform fills ${seagit.app.tls_secret})" -}}
{{- end -}}
{{- if ne (toJson $jh.proxy.https.hosts) (toJson (list .Values.public.host)) -}}
{{- fail (printf "jupyterhub.proxy.https.hosts must be [%s]" .Values.public.host) -}}
{{- end -}}
{{- if ne (toString $jh.proxy.https.secret.name) (toString .Values.public.tlsSecret) -}}
{{- fail "jupyterhub.proxy.https.secret.name must equal public.tlsSecret" -}}
{{- end -}}
{{- if ne (toString (index $jh.proxy.service.annotations "external-dns.alpha.kubernetes.io/hostname")) (toString .Values.public.leafHost) -}}
{{- fail "jupyterhub.proxy.service external-dns hostname annotation must equal public.leafHost" -}}
{{- end -}}
{{- if not (has (index $jh.proxy.service.annotations "service.beta.kubernetes.io/aws-load-balancer-scheme") (list "internet-facing" "internal")) -}}
{{- fail "jupyterhub.proxy.service load balancer scheme must be internet-facing or internal" -}}
{{- end -}}
{{- range $jh.proxy.service.loadBalancerSourceRanges -}}
{{- if not (regexMatch "^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])[.]){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])/([0-9]|[12][0-9]|3[0-2])$" (toString .)) -}}
{{- fail (printf "allowed IPs: %q is not an IPv4 CIDR such as 203.0.113.7/32" (toString .)) -}}
{{- end -}}
{{- end -}}
{{- if not .Values.serviceAccount.name -}}
{{- fail "serviceAccount.name is required (the platform fills ${seagit.app.sa_name})" -}}
{{- end -}}
{{- if ne (toString $jh.singleuser.serviceAccountName) (toString .Values.serviceAccount.name) -}}
{{- fail "jupyterhub.singleuser.serviceAccountName must equal serviceAccount.name" -}}
{{- end -}}
{{- if not (has $auth.type (list "password" "github" "oidc")) -}}
{{- fail (printf "jupyterhub.custom.auth.type must be password, github or oidc, got %q" (toString $auth.type)) -}}
{{- end -}}
{{- if eq $auth.type "password" -}}
{{- if lt (len (toString $auth.adminPassword)) 32 -}}
{{- fail "password sign-in: custom.auth.adminPassword must be at least 32 characters" -}}
{{- end -}}
{{- if lt (len (toString $auth.userPassword)) 8 -}}
{{- fail "password sign-in: custom.auth.userPassword must be at least 8 characters" -}}
{{- end -}}
{{- if eq (toString $auth.adminPassword) (toString $auth.userPassword) -}}
{{- fail "password sign-in: the admin and user passwords must differ" -}}
{{- end -}}
{{- if not (include "sg-notebooks.csv" $auth.admins | fromJsonArray) -}}
{{- fail "password sign-in needs at least one admin username" -}}
{{- end -}}
{{- else -}}
{{- if not (and $auth.clientId $auth.clientSecret) -}}
{{- fail (printf "%s sign-in needs custom.auth.clientId and clientSecret" $auth.type) -}}
{{- end -}}
{{- if ne (toString $auth.callbackUrl) (printf "https://%s/hub/oauth_callback" .Values.public.host) -}}
{{- fail (printf "custom.auth.callbackUrl must be https://%s/hub/oauth_callback" .Values.public.host) -}}
{{- end -}}
{{- if and (eq $auth.type "github") (not (include "sg-notebooks.csv" $auth.github.organizations | fromJsonArray)) -}}
{{- fail "GitHub sign-in needs at least one organization (or organization:team)" -}}
{{- end -}}
{{- if and (eq $auth.type "oidc") (not (regexMatch "^https://[^\\s]+$" (toString $auth.oidc.issuer))) -}}
{{- fail "OIDC sign-in needs an https issuer URL" -}}
{{- end -}}
{{- end -}}
{{- range (include "sg-notebooks.csv" $jh.custom.sizes | fromJsonArray) -}}
{{- if not (has . (list "xsmall" "small" "medium" "large" "xlarge")) -}}
{{- fail (printf "custom.sizes: unknown size %q (xsmall, small, medium, large, xlarge)" .) -}}
{{- end -}}
{{- end -}}
{{- if not (include "sg-notebooks.csv" $jh.custom.sizes | fromJsonArray) -}}
{{- fail "custom.sizes needs at least one size" -}}
{{- end -}}
{{- $imageRe := "^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+(:[A-Za-z0-9._-]+|@sha256:[a-f0-9]{64})$" -}}
{{- if and (has "custom" (include "sg-notebooks.csv" $jh.custom.images | fromJsonArray)) (not (regexMatch $imageRe (toString $jh.custom.customImage))) -}}
{{- fail (printf "custom.customImage must be a full image reference such as 123456789012.dkr.ecr.us-east-1.amazonaws.com/team/notebook:1.0, got %q" (toString $jh.custom.customImage)) -}}
{{- end -}}
{{- if not (has (toString $jh.custom.bucketMode) (list "new" "existing")) -}}
{{- fail "custom.bucketMode must be new or existing" -}}
{{- end -}}
{{- range (include "sg-notebooks.csv" $jh.custom.images | fromJsonArray) -}}
{{- if not (or (eq . "custom") (hasKey $jh.custom.imageCatalog .) (regexMatch "^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+(:[A-Za-z0-9._-]+|@sha256:[a-f0-9]{64})$" .)) -}}
{{- fail (printf "custom.images: %q is neither a catalog image (%s) nor a full image reference such as 123456789012.dkr.ecr.us-east-1.amazonaws.com/team/notebook:1.0" . (keys $jh.custom.imageCatalog | sortAlpha | join ", ")) -}}
{{- end -}}
{{- end -}}
{{- end }}
