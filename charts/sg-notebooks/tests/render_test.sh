#!/usr/bin/env bash
# Render assertions for sg-notebooks (no cluster needed). Run from the repo root.
set -euo pipefail
chart=charts/sg-notebooks
helm dependency build "$chart" >/dev/null
fail() { echo "FAIL: $1"; exit 1; }
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
host=nb1.ns.example.com; leaf=nb1-sgt-code1.ns.example.com
cat > "$tmp" <<EOF
public: { host: $host, leafHost: $leaf, tlsSecret: nb1-tls, certIssuer: dns01-letsencrypt-ns-example-com }
seagit: { deploymentId: dep123 }
serviceAccount: { name: k8s-code1-nb1, roleArn: "arn:aws:iam::111122223333:role/sgt-app-code1-nb1" }
jupyterhub:
  custom:
    auth: { type: password, admins: alice, allowedUsers: "bob, carol", adminPassword: "$(printf 'A%.0s' {1..43})", userPassword: "$(printf 'B%.0s' {1..43})" }
    bucket: env-nb-abc123
    region: us-east-1
  proxy:
    https: { hosts: [$host], secret: { name: nb1-tls } }
    service:
      annotations: { external-dns.alpha.kubernetes.io/hostname: $leaf }
      loadBalancerSourceRanges: [203.0.113.7/32]
  singleuser: { serviceAccountName: k8s-code1-nb1 }
EOF
render() { helm template nb1 "$chart" -n apps -f "$tmp" "$@"; }
refused() { if helm template nb1 "$chart" -n apps -f "$tmp" "$@" >/dev/null 2>&1; then fail "accepted: $*"; fi; }
doc() { awk -v k="$1" -v n="$2" 'BEGIN{RS="\n---\n"} $0 ~ "kind: "k"\n" && $0 ~ "name: "n"\n" {print}' <<<"$out"; }

out=$(render)

# --- nothing cluster-scoped; the only hooks are the pre-delete cleanup ---
grep -E '^kind: (ClusterRole|ClusterRoleBinding|PriorityClass|StorageClass|CustomResourceDefinition|DaemonSet)$' <<<"$out" \
  && fail "cluster-scoped or node-wide object rendered"
[ "$(grep -c 'helm.sh/hook: pre-delete' <<<"$out")" = 4 ] || fail "cleanup hook: SA, Role, RoleBinding, Job"
grep 'helm.sh/hook:' <<<"$out" | grep -v pre-delete && fail "unexpected hook"
grep -q 'kind: Ingress' <<<"$out" && fail "no Ingress: the hub has its own NLB"

# --- release-prefixed names (two hubs can share a namespace) ---
for n in nb1-notebooks-hub nb1-notebooks-proxy nb1-notebooks-proxy-public nb1-notebooks-hub-db-dir; do grep -q "name: $n$" <<<"$out" || fail "name $n"; done
grep -E '^  name: (hub|proxy|proxy-public)$' <<<"$out" && fail "unprefixed upstream name"

# --- exposure: NLB + TLS in the proxy from the platform secret ---
svc=$(doc Service nb1-notebooks-proxy-public)
grep -q 'type: LoadBalancer' <<<"$svc" || fail "proxy-public LoadBalancer"
grep -q 'aws-load-balancer-scheme: internet-facing' <<<"$svc" || fail "NLB scheme"
grep -q 'aws-load-balancer-nlb-target-type: ip' <<<"$svc" || fail "NLB ip targets"
grep -q 'aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true' <<<"$svc" || fail "NLB cross-zone"
grep -q "external-dns.alpha.kubernetes.io/hostname: $leaf" <<<"$svc" || fail "leaf hostname"
grep -q 'seagit.io/report-address: "true"' <<<"$svc" || fail "report-address label"
grep -q 'app.kubernetes.io/instance: "\?nb1"\?$' <<<"$svc" || fail "instance label (lb report selector)"
grep -A1 'loadBalancerSourceRanges' <<<"$svc" | grep -q '203.0.113.7/32' || fail "allowlist"
grep -q 'secretName: nb1-tls' <<<"$(doc Deployment nb1-notebooks-proxy)" || fail "proxy mounts the TLS secret"
grep -q 'name: autohttps' <<<"$out" && fail "no traefik/ACME"
cert=$(doc Certificate nb1-tls)
grep -q "name: dns01-letsencrypt-ns-example-com" <<<"$cert" || fail "certificate issuer"
grep -q -- "- $host" <<<"$cert" && grep -q -- "- $leaf" <<<"$cert" || fail "certificate names"
grep -q 'seagit.io/deployment: dep123' <<<"$cert" || fail "certificate secret owner label"
grep -q 'kind: Certificate' <<<"$(render --set public.certIssuer=)" && fail "wildcard: no Certificate"

# --- IRSA service account for the servers ---
sa=$(doc ServiceAccount k8s-code1-nb1)
grep -q 'eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/sgt-app-code1-nb1' <<<"$sa" || fail "IRSA annotation"
grep -q 'automountServiceAccountToken: false' <<<"$sa" || fail "no API token on the server SA"

# --- cleanup hook targets only this hub's servers ---
job=$(doc Job nb1-cleanup)
grep -q -- '--selector=app.kubernetes.io/instance=nb1,app.kubernetes.io/managed-by=kubespawner' <<<"$job" || fail "cleanup selector"
grep -q -- '- pods,persistentvolumeclaims' <<<"$job" || fail "cleanup deletes homes by default"
grep -q -- '- pods$' <<<"$(render --set cleanup.deleteHomes=false | awk 'BEGIN{RS="\n---\n"} /name: nb1-cleanup\n/ && /kind: Job/')" || fail "deleteHomes=false keeps homes"
grep -q 'resourceNames: \["nb1-notebooks-proxy"\]' <<<"$(doc Role nb1-cert-reload)" || fail "cert reload limited to the proxy"

# --- safe upstream defaults ---
grep -E '^  name: nb1-user-scheduler' <<<"$out" && fail "user scheduler (cluster-scoped RBAC)"
grep -E '^  name: nb1-.*image-puller' <<<"$out" && fail "image puller"
grep -q 'kind: NetworkPolicy' <<<"$out" || fail "network policies on"

# --- validation ---
refused --set public.host=
refused --set public.leafHost=not_a_host
refused --set public.tlsSecret=
refused --set 'jupyterhub.proxy.https.hosts[0]=other.example.com'
refused --set jupyterhub.proxy.https.secret.name=other-tls
refused --set 'jupyterhub.proxy.service.annotations.external-dns\.alpha\.kubernetes\.io/hostname=x.example.com'
refused --set 'jupyterhub.proxy.service.loadBalancerSourceRanges[0]=10.0.0.0/33'
refused --set jupyterhub.singleuser.serviceAccountName=other
refused --set serviceAccount.name=
refused --set jupyterhub.custom.auth.type=ldap
refused --set jupyterhub.custom.auth.adminPassword=short
refused --set jupyterhub.custom.auth.userPassword=short
refused --set jupyterhub.custom.auth.admins=
refused --set jupyterhub.custom.sizes=huge
refused --set jupyterhub.custom.sizes=
refused --set 'jupyterhub.custom.images=not an image'
refused --set jupyterhub.custom.images=custom
refused --set jupyterhub.custom.images=custom --set jupyterhub.custom.customImage=latest
render --set jupyterhub.custom.images=scipy\\,custom --set jupyterhub.custom.customImage=123456789012.dkr.ecr.us-east-1.amazonaws.com/team/nb:1.0 >/dev/null || fail "custom image choice refused"
refused --set jupyterhub.custom.bucketMode=other
render --set 'jupyterhub.custom.images=123456789012.dkr.ecr.us-east-1.amazonaws.com/team/nb:1.0' >/dev/null || fail "custom ECR image refused"
gh=(--set jupyterhub.custom.auth.type=github --set jupyterhub.custom.auth.clientId=id --set jupyterhub.custom.auth.clientSecret=s
    --set jupyterhub.custom.auth.github.organizations=acme)
refused "${gh[@]}"   # no callback URL
render "${gh[@]}" --set "jupyterhub.custom.auth.callbackUrl=https://$host/hub/oauth_callback" >/dev/null || fail "github accepted"
refused "${gh[@]}" --set "jupyterhub.custom.auth.callbackUrl=https://evil.example.com/hub/oauth_callback"
refused --set jupyterhub.custom.auth.type=github --set jupyterhub.custom.auth.clientId=id --set jupyterhub.custom.auth.clientSecret=s \
  --set "jupyterhub.custom.auth.callbackUrl=https://$host/hub/oauth_callback"   # no organization
oidc=(--set jupyterhub.custom.auth.type=oidc --set jupyterhub.custom.auth.clientId=id --set jupyterhub.custom.auth.clientSecret=s
      --set "jupyterhub.custom.auth.callbackUrl=https://$host/hub/oauth_callback")
render "${oidc[@]}" --set jupyterhub.custom.auth.oidc.issuer=https://acme.okta.com/oauth2/default >/dev/null || fail "oidc accepted"
refused "${oidc[@]}" --set jupyterhub.custom.auth.oidc.issuer=http://acme.okta.com
refused "${oidc[@]}" --set jupyterhub.custom.auth.clientSecret= --set jupyterhub.custom.auth.oidc.issuer=https://acme.okta.com

# --- secrets stay out of ConfigMaps ---
for pw in "$(printf 'A%.0s' {1..43})" "$(printf 'B%.0s' {1..43})"; do
  awk 'BEGIN{RS="\n---\n"} /kind: ConfigMap/' <<<"$out" | grep -q "$pw" && fail "password in a ConfigMap"
done
# --- node pool placement (ops test 2026-10-15): the record passes ${seagit.app.node_selector|tolerations}
# (JSON flow values) to the chart's own pods AND the hub, proxy and notebook servers ---
pl_tmp=$(mktemp)
cat >"$pl_tmp" <<'YAML'
nodeSelector: {"cluster-autoscaler/pool":"builds"}
tolerations: [{"effect":"NoSchedule","key":"cluster-autoscaler/pool","operator":"Equal","value":"builds"}]
jupyterhub:
  hub:
    nodeSelector: {"cluster-autoscaler/pool":"builds"}
    tolerations: [{"effect":"NoSchedule","key":"cluster-autoscaler/pool","operator":"Equal","value":"builds"}]
  proxy:
    chp:
      nodeSelector: {"cluster-autoscaler/pool":"builds"}
      tolerations: [{"effect":"NoSchedule","key":"cluster-autoscaler/pool","operator":"Equal","value":"builds"}]
  singleuser:
    nodeSelector: {"cluster-autoscaler/pool":"builds"}
    extraTolerations: [{"effect":"NoSchedule","key":"cluster-autoscaler/pool","operator":"Equal","value":"builds"}]
YAML
pl=$(render -f "$pl_tmp"); rm -f "$pl_tmp"
for k in "Deployment nb1-notebooks-hub" "Deployment nb1-notebooks-proxy" "CronJob nb1-cert-reload" "Job nb1-cleanup"; do
  d=$(out="$pl" doc ${k% *} ${k#* })
  [ -n "$d" ] || fail "placement: no $k rendered"
  grep -A1 'nodeSelector:$' <<<"$d" | grep -q 'cluster-autoscaler/pool: builds' || fail "placement: $k nodeSelector"
  grep -q 'key: cluster-autoscaler/pool' <<<"$d" || fail "placement: $k toleration"
done
grep -q 'cluster-autoscaler/pool' <<<"$out" && fail "default must not pin a pool"
# --- sign-in through an oauth2-proxy (custom.auth.type=proxy), 0.1.2 ---
px=$(mktemp)
cat >"$px" <<'YAML'
jupyterhub:
  custom:
    auth:
      type: proxy
      admins: "alice@acme.io"
      proxy:
        mode: existing
        authUrl: http://auth-application.idp.svc.cluster.local:4180/oauth2/auth
        signinUrl: https://auth.ns.example.com/oauth2/start
        signoutUrl: https://auth.ns.example.com/oauth2/sign_out
        allowedGroups: "data science"
YAML
ex=$(render -f "$px")
grep -q 'notebooks-auth' <<<"$ex" && fail "existing Auth Proxy must not render a sign-in proxy"
grep -q 'kind: Deployment' <<<"$(out="$ex" doc Deployment nb1-notebooks-hub)" || fail "existing: hub rendered"
refused -f "$px" --set jupyterhub.custom.auth.proxy.authUrl="javascript:alert(1)"
refused -f "$px" --set jupyterhub.custom.auth.proxy.signinUrl=http://auth.ns.example.com/oauth2/start
refused -f "$px" --set jupyterhub.custom.auth.proxy.mode=other
# 0.1.3: logout ends the Auth Proxy session, so its sign-out address is required and must be plain https
refused -f "$px" --set jupyterhub.custom.auth.proxy.signoutUrl=
refused -f "$px" --set jupyterhub.custom.auth.proxy.signoutUrl=http://auth.ns.example.com/oauth2/sign_out
refused -f "$px" --set-string 'jupyterhub.custom.auth.proxy.signoutUrl=https://auth.ns.example.com/oauth2/sign_out?rd=https://evil.example'
refused -f "$px" --set jupyterhub.custom.auth.proxy.usernameFrom=sub
CSEC="client-secret-$(printf 'C%.0s' {1..30})"
cat >"$px" <<YAML
jupyterhub:
  custom:
    auth:
      type: proxy
      admins: "alice@acme.io"
      proxy: { mode: new }
signInProxy:
  provider: github
  clientId: Iv1.abc
  clientSecret: $CSEC
  cookieSecret: "$(printf 'k%.0s' {1..32})"
  github: { org: acme, team: data }
nodeSelector: {"cluster-autoscaler/pool":"builds"}
tolerations: [{"effect":"NoSchedule","key":"cluster-autoscaler/pool","operator":"Equal","value":"builds"}]
YAML
nw=$(render -f "$px")
dep=$(out="$nw" doc Deployment nb1-notebooks-auth)
[ -n "$dep" ] || fail "new: sign-in proxy Deployment"
grep -q 'OAUTH2_PROXY_PROXY_PREFIX, value: "/services/auth"' <<<"$dep" || fail "new: proxy prefix"
grep -q "OAUTH2_PROXY_REDIRECT_URL, value: \"https://$host/services/auth/callback\"" <<<"$dep" || fail "new: callback on the hub host"
grep -q 'OAUTH2_PROXY_UPSTREAMS, value: "static://202"' <<<"$dep" || fail "new: proxies nothing"
grep -q 'OAUTH2_PROXY_GITHUB_ORG, value: "acme"' <<<"$dep" || fail "new: github org"
grep -q 'OAUTH2_PROXY_GITHUB_TEAM, value: "data"' <<<"$dep" || fail "new: github team"
grep -q 'OAUTH2_PROXY_EMAIL_DOMAINS' <<<"$dep" && fail "new github: no email-domain env"
grep -A1 'nodeSelector:$' <<<"$dep" | grep -q 'cluster-autoscaler/pool: builds' || fail "new: sign-in proxy on the node pool"
grep -q 'name: nb1-notebooks-auth$' <<<"$(out="$nw" doc Service nb1-notebooks-auth)" || fail "new: in-cluster service"
grep -q 'type: ClusterIP' <<<"$(out="$nw" doc Service nb1-notebooks-auth)" || fail "new: never exposed on its own"
grep -q "$CSEC" <<<"$dep" && fail "new: client secret in the Deployment"
grep -q "$CSEC" <<<"$(out="$nw" doc Secret nb1-notebooks-auth)" || fail "new: client secret in its Secret"
awk 'BEGIN{RS="\n---\n"} /kind: ConfigMap/' <<<"$nw" | grep -q "$CSEC" && fail "new: client secret in a ConfigMap"
grep -q "$CSEC" <<<"$(out="$nw" doc Secret nb1-notebooks-hub)" && fail "new: client secret in the hub's config"
refused -f "$px" --set signInProxy.clientSecret=
refused -f "$px" --set signInProxy.cookieSecret=short
refused -f "$px" --set signInProxy.github.org=
refused -f "$px" --set signInProxy.provider=saml
refused -f "$px" --set signInProxy.provider=oidc --set signInProxy.oidc.issuer=http://idp.example.com
refused -f "$px" --set signInProxy.provider=google
refused -f "$px" --set signInProxy.provider=google --set signInProxy.google.domains="*"
og=$(render -f "$px" --set signInProxy.provider=google --set signInProxy.google.domains=acme.io)
grep -q 'OAUTH2_PROXY_EMAIL_DOMAINS, value: "acme.io"' <<<"$(out="$og" doc Deployment nb1-notebooks-auth)" || fail "new google: email domains"
grep -q 'OAUTH2_PROXY_CODE_CHALLENGE_METHOD, value: "S256"' <<<"$(out="$og" doc Deployment nb1-notebooks-auth)" || fail "new google: PKCE"
grep -q 'OAUTH2_PROXY_CODE_CHALLENGE_METHOD' <<<"$dep" && fail "new github: no PKCE (GitHub OAuth apps)"
rm -f "$px"
echo "PASS"
