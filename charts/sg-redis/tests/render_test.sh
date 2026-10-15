#!/usr/bin/env bash
# Render assertions for sg-redis (no cluster needed). Run from the repo root.
set -euo pipefail
chart=charts/sg-redis
helm dependency build "$chart" >/dev/null
fail() { echo "FAIL: $1"; exit 1; }
PW=abcdefghijklmnop0123456789
base=(--set auth.password=$PW --set seagit.deploymentId=dep123 --set serviceAccount.name=k8s-code1-r1
      --set serviceAccount.roleArn=arn:aws:iam::111122223333:role/sgt-app-code1-r1
      --set backup.bucket=env-redis-abc123 --set backup.region=us-east-1)
pub=(--set reach=public --set public.leafHost=r1-sgt-code1.ns.example.com --set public.tlsSecret=ns-example-com-tls)
render() { helm template r1 "$chart" -n apps "${base[@]}" "$@"; }
refused() { if helm template r1 "$chart" -n apps "${base[@]}" "$@" >/dev/null 2>&1; then fail "accepted: $*"; fi; }
cidrs() { printf 'public:\n  allowedCidrs: "%s"\n' "$1" > "$tmp"; }
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

# --- engines ---
vk=$(render)
grep -q 'image: "valkey/valkey:8.1"' <<<"$vk" || fail "valkey image"
grep -q 'exec valkey-server /etc/redis/redis.conf' <<<"$vk" || fail "valkey server"
rd=$(render --set engine=redis)
grep -q 'image: "redis:8.2"' <<<"$rd" || fail "redis image"
grep -q 'exec redis-server /etc/redis/redis.conf' <<<"$rd" || fail "redis server"
grep -q 'redis-cli -p 6379 ping' <<<"$rd" || fail "redis readiness cli"
refused --set engine=memcached

# --- password never on a command line or in a ConfigMap ---
grep -q "$PW" <<<"$(grep -v 'PASSWORD: ' <<<"$vk")" && fail "password outside the Secret"
grep -q 'include /run/redis/auth.conf' <<<"$vk" || fail "auth include"
refused --set auth.password=
refused --set auth.password=short
refused --set 'auth.password=has"quote0123456789'

# --- sizes ---
grep -q 'maxmemory 96mb' <<<"$vk" || fail "small maxmemory"
grep -A3 'limits:' <<<"$vk" | grep -q 'memory: 128Mi' || fail "small limit"
grep -q 'maxmemory 384mb' <<<"$(render --set size=medium)" || fail "medium maxmemory"
refused --set size=huge
grep -q 'maxmemory-policy allkeys-lru' <<<"$(render --set evictionPolicy=allkeys-lru)" || fail "eviction policy"
refused --set evictionPolicy=lru
grep -q 'appendonly yes' <<<"$vk" || fail "AOF on"
grep -q 'maxclients 1000' <<<"$vk" || fail "maxclients cap"

# --- reach ---
grep -q 'name: r1-vpc' <<<"$vk" && fail "cluster: no vpc service"
grep -q 'name: r1-public' <<<"$vk" && fail "cluster: no public service"
grep -q 'tls-port' <<<"$vk" && fail "cluster: no TLS"
vpc=$(render --set reach=vpc)
grep -q 'aws-load-balancer-scheme: internal' <<<"$vpc" || fail "vpc internal NLB"
grep -A10 'name: r1-vpc' <<<"$vpc" | grep -q 'seagit.io/report-address: "true"' || fail "vpc report-address"
p=$(render "${pub[@]}")
grep -A20 'name: r1-public' <<<"$p" | grep -q 'aws-load-balancer-scheme: internet-facing' || fail "public NLB scheme"
grep -A20 'name: r1-public' <<<"$p" | grep -q 'external-dns.alpha.kubernetes.io/hostname: r1-sgt-code1.ns.example.com' || fail "leaf hostname"
grep -A20 'name: r1-public' <<<"$p" | grep -q 'cloudflare-proxied: "false"' || fail "cloudflare unproxied"
grep -A30 'name: r1-public' <<<"$p" | grep -q 'targetPort: tls' || fail "public -> TLS port"
grep -q 'loadBalancerSourceRanges' <<<"$p" && fail "empty allowlist = open (no sourceRanges)"
grep -q 'tls-port 6380' <<<"$p" || fail "TLS port"
grep -q 'secretName: ns-example-com-tls' <<<"$p" || fail "TLS secret mount"
grep -q 'name: tls-reload' <<<"$p" || fail "cert reload sidecar"
grep -q 'name: tls-reload' <<<"$vk" && fail "no reload sidecar without TLS"
grep -q 'kind: Certificate' <<<"$p" && fail "wildcard secret (no certIssuer): no Certificate"
pc=$(render "${pub[@]}" --set public.certIssuer=dns01-le --set public.host=r1.ns.example.com --set public.tlsSecret=r1-tls)
grep -A22 'kind: Certificate' <<<"$pc" | grep -q 'secretName: r1-tls' || fail "Certificate secret"
grep -A22 'kind: Certificate' <<<"$pc" | grep -q 'name: dns01-le' || fail "Certificate issuer"
grep -A22 'kind: Certificate' <<<"$pc" | grep -q -- '- r1.ns.example.com' || fail "Certificate host"
grep -A22 'kind: Certificate' <<<"$pc" | grep -q -- '- r1-sgt-code1.ns.example.com' || fail "Certificate leaf"
grep -A22 'kind: Certificate' <<<"$pc" | grep -q 'seagit.io/deployment: dep123' || fail "TLS secret owner label (destroy cleanup)"
refused "${pub[@]}" --set public.certIssuer=dns01-le
grep -q 'kind: Certificate' <<<"$(render --set public.certIssuer=x)" && fail "cluster reach: no Certificate"
cidrs "203.0.113.7/32, 10.0.0.0/8"
pa=$(render "${pub[@]}" -f "$tmp")
grep -A3 'loadBalancerSourceRanges' <<<"$pa" | grep -q -- '- 203.0.113.7/32' || fail "allowlist entry 1"
grep -A3 'loadBalancerSourceRanges' <<<"$pa" | grep -q -- '- 10.0.0.0/8' || fail "allowlist entry 2"
for bad in "10.0.0.0" "300.1.1.1/32" "10.0.0.0/33" "foo" "1.2.3.4/32; rm"; do
  cidrs "$bad"; refused "${pub[@]}" -f "$tmp"
done
refused --set reach=public --set public.tlsSecret=x
refused --set reach=public --set public.leafHost=r1.example.com
refused --set reach=internet

# --- platform labels / scheduling ---
grep -q 'seagit.io/deployment: dep123' <<<"$vk" || fail "owner label"
grep -A6 'volumeClaimTemplates' <<<"$vk" | grep -q 'app.kubernetes.io/instance: r1' || fail "PVC instance label"
grep -q 'storageClassName: ebs-csi-slow-del' <<<"$vk" || fail "storage class"
grep -q 'key: node.kubernetes.io/lifecycle' <<<"$vk" || fail "off-spot affinity"
grep -q 'eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/sgt-app-code1-r1' <<<"$vk" || fail "IRSA"
grep -q 'priorityClassName: seagit-stateful' <<<"$(render --set priorityClassName=seagit-stateful)" || fail "priority class"

# --- backups (library) ---
grep -q '"helm.sh/hook": post-install' <<<"$vk" || fail "first backup hook"
grep -q '"helm.sh/hook": pre-delete' <<<"$vk" || fail "final backup hook"
grep -q '"helm.sh/hook": pre-delete' <<<"$(render --set backup.onDelete=false)" && fail "onDelete=false drops final hook"
grep -q 'kind: CronJob' <<<"$vk" || fail "nightly CronJob"
grep -q -- '--rdb /work/dump.rdb' <<<"$vk" || fail "rdb dump"
grep -q 'name="${ts}.rdb.gz"' <<<"$vk" || fail "rdb.gz object name"
grep -q 'Z\\.rdb\\.gz\$' <<<"$vk" || fail "prune regex for rdb.gz"
grep -q 'redis not running' <<<"$vk" || fail "not-running message"
refused --set backup.bucket=
refused --set backup.prefix=nofolder
# --- node pool placement: the worker renders ${seagit.app.node_selector|tolerations} as JSON flow
# values; EVERY pod (data, nightly, first, final backup) must land on that pool (ops test 2026-10-15) ---
placement_values=$(mktemp)
cat >"$placement_values" <<'YAML'
nodeSelector: {"cluster-autoscaler/pool":"builds"}
tolerations: [{"effect":"NoSchedule","key":"cluster-autoscaler/pool","operator":"Equal","value":"builds"}]
YAML
pl=$(render -f "$placement_values")
rm -f "$placement_values"
[ "$(grep -c '^ *nodeSelector:$' <<<"$pl")" = 4 ] || fail "nodeSelector on all 4 pods"
[ "$(grep -A1 '^ *nodeSelector:$' <<<"$pl" | grep -c 'cluster-autoscaler/pool: builds')" = 4 ] || fail "pool selector value"
[ "$(grep -A1 '^ *tolerations:$' <<<"$pl" | grep -c 'effect: NoSchedule')" = 4 ] || fail "pool toleration on all 4 pods"
grep -q 'key: node.kubernetes.io/lifecycle' <<<"$pl" || fail "placement must keep the off-spot affinity"
grep -q -E 'nodeSelector:|tolerations:' <<<"$vk" && fail "default must not pin a pool"
echo "render_test: OK"
