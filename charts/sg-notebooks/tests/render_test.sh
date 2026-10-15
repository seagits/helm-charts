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
echo "PASS"
