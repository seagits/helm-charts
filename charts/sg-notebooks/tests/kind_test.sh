#!/usr/bin/env bash
# Integration test on a throwaway kind cluster. Run from the repo root.
# Needs: kind, kubectl, helm, openssl, node >= 22. Deletes the cluster on exit (KEEP=1 keeps it).
# Proves: install with no cluster-scoped objects; shared-password sign-in (admin, allowed user,
# refused user, wrong password); a server starts with the chosen size and image, runs as the IRSA
# service account with no Kubernetes token; code runs in a kernel; the home survives a restart; the
# idle culler stops a server; uninstall removes the servers and homes the hub made.
set -euo pipefail
chart=charts/sg-notebooks; ns=nbtest; rel=nb1; cl=${CLUSTER:-sgnotebooks-test}
here=$(cd "$(dirname "$0")" && pwd)
fail() { echo "FAIL: $1"; exit 1; }
step() { echo "--- $(date +%H:%M:%S) $1"; }
helm dependency build "$chart" >/dev/null
kind create cluster --name "$cl" >/dev/null
work=$(mktemp -d)
cleanup() { [ -n "${pf:-}" ] && kill "$pf" 2>/dev/null; rm -rf "$work"; [ "${KEEP:-}" = 1 ] || kind delete cluster --name "$cl" >/dev/null; }
trap cleanup EXIT
kubectl config use-context "kind-$cl" >/dev/null
kubectl create ns "$ns" >/dev/null

host=nb1.ns.example.com; leaf=nb1-sgt-kind.ns.example.com
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$host" -addext "subjectAltName=DNS:$host,DNS:$leaf" \
  -keyout "$work/tls.key" -out "$work/tls.crt" 2>/dev/null
# The secret appears ~45 s into the install, as cert-manager's would (DNS-01 takes minutes): the
# proxy waits for it and the hub must wait for the proxy without restarting.
( sleep 45; kubectl -n "$ns" create secret tls nb1-tls --cert="$work/tls.crt" --key="$work/tls.key" >/dev/null ) &

ADMIN_PW=$(openssl rand -hex 24); USER_PW=$(openssl rand -hex 12); TOKEN=$(openssl rand -hex 32)
cat > "$work/values.yaml" <<EOF
public: { host: $host, leafHost: $leaf, tlsSecret: nb1-tls, certIssuer: "" }
seagit: { deploymentId: dep-kind }
serviceAccount: { name: k8s-kind-nb1, roleArn: "arn:aws:iam::111122223333:role/sgt-app-kind-nb1" }
jupyterhub:
  custom:
    auth: { type: password, admins: alice, allowedUsers: "bob", adminPassword: "$ADMIN_PW", userPassword: "$USER_PW" }
    sizes: small,medium
    images: scipy,pytorch
    avoidSpot: false
    bucket: env-nb-kind
    region: us-east-1
  hub:
    db: { pvc: { storageClassName: standard } }
    services: { kindtest: { api_token: "$TOKEN" } }
    loadRoles:
      kindtest: { services: [kindtest], scopes: [admin:users, admin:servers, access:servers, read:users] }
  singleuser:
    serviceAccountName: k8s-kind-nb1
    storage: { capacity: 1Gi, dynamic: { storageClass: standard } }
  cull: { timeout: 120, every: 30 }
EOF

step "install"
t0=$(date +%s)
helm install "$rel" "$chart" -n "$ns" -f "$work/values.yaml" --wait --timeout 10m >/dev/null || {
  kubectl -n "$ns" get pods; kubectl -n "$ns" logs deploy/nb1-notebooks-hub --tail=60 || true; fail "install"; }
echo "installed in $(( $(date +%s) - t0 ))s"
restarts=$(kubectl -n "$ns" get pod -l component=hub -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
[ "$restarts" = 0 ] || fail "hub restarted $restarts time(s) during install"
cluster_scoped=$( (helm get manifest "$rel" -n "$ns"; helm get hooks "$rel" -n "$ns") | grep -E '^kind: (ClusterRole|ClusterRoleBinding|PriorityClass|StorageClass|CustomResourceDefinition|Namespace)$' || true)
[ -z "$cluster_scoped" ] || fail "cluster-scoped objects in the release: $cluster_scoped"

# Shared exposure (the 0.1.6 default): the proxy is plain HTTP behind the cluster's entrance, which
# this cluster does not have; the hub is driven straight through the proxy. The entrance (nginx, or
# Envoy through the Gateway API route sync) is tested by ingress_test.sh on the gateway rigs.
kubectl -n "$ns" get ingress nb1-notebooks >/dev/null || fail "no Ingress for the shared entrance"
kubectl -n "$ns" get svc nb1-notebooks-proxy-public -o jsonpath='{.spec.type}' | grep -qx ClusterIP || fail "proxy-public is not ClusterIP"
kubectl -n "$ns" port-forward svc/nb1-notebooks-proxy-public 28080:80 >/dev/null 2>&1 & pf=$!
export HUB=http://127.0.0.1:28080 TOKEN
for i in $(seq 30); do curl -s -o /dev/null "$HUB/hub/login" && break; sleep 1; done
c() { node "$here/hub_client.mjs" "$@"; }

step "sign-in"
[ "$(c login alice "$ADMIN_PW")" = ok ] || fail "admin sign-in"
[ "$(c login bob "$USER_PW")" = ok ] || fail "allowed user sign-in"
[ "$(c login bob wrong-password-123)" = refused ] || fail "wrong password accepted"
[ "$(c login mallory "$USER_PW")" = refused ] || fail "user not on the allowed list accepted"
[ "$(c login bob "$ADMIN_PW")" = refused ] || fail "admin password accepted for a non-admin"

step "start bob: medium + pytorch"
t0=$(date +%s)
c start bob medium pytorch 900 >/dev/null
echo "server ready in $(( $(date +%s) - t0 ))s"
pod=$(kubectl -n "$ns" get pod -l app.kubernetes.io/instance=$rel,app.kubernetes.io/managed-by=kubespawner,hub.jupyter.org/username=bob -o name)
[ -n "$pod" ] || fail "no server pod for bob"
spec=$(kubectl -n "$ns" get "$pod" -o json)
jq -e '.spec.serviceAccountName == "k8s-kind-nb1"' <<<"$spec" >/dev/null || fail "server not on the IRSA service account"
jq -e '.spec.automountServiceAccountToken == false' <<<"$spec" >/dev/null || fail "server has a Kubernetes API token"
jq -e '.spec.containers[0].image == "quay.io/jupyter/pytorch-notebook:2026-09-28"' <<<"$spec" >/dev/null || fail "image choice ignored"
jq -e '.spec.containers[0].resources.limits.cpu == "2" and .spec.containers[0].resources.limits.memory == "8589934592"' <<<"$spec" >/dev/null \
  || fail "medium size not applied: $(jq -c '.spec.containers[0].resources' <<<"$spec")"
jq -e '[.spec.containers[0].env[] | select(.name=="SEAGIT_BUCKET" and .value=="env-nb-kind")] | length == 1' <<<"$spec" >/dev/null || fail "SEAGIT_BUCKET env"
jq -e '.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution == null' <<<"$spec" >/dev/null || fail "avoidSpot=false still sets node affinity"

step "run code + write to home"
out=$(c run bob 'import os, torch; print(6*7, os.environ["SEAGIT_BUCKET"]); open(os.path.expanduser("~/persist.txt"),"w").write("kept")')
grep -q '^42 env-nb-kind' <<<"$out" || fail "kernel output: $out"

step "terminal + upload"
[ "$(c term bob)" = term-42 ] || fail "terminal round trip"
[ "$(c upload bob 5)" = 201 ] || fail "5 MiB upload through the contents API"

step "home survives a restart"
c stop bob >/dev/null
c start bob small scipy 600 >/dev/null
out=$(c run bob 'print(open("/home/jovyan/persist.txt").read())')
grep -q '^kept' <<<"$out" || fail "home not kept across restart: $out"

step "idle culler stops the server (timeout 120s)"
t0=$(date +%s)
c wait-stopped bob 420 >/dev/null || fail "culler did not stop bob"
echo "culled after $(( $(date +%s) - t0 ))s idle"
kubectl -n "$ns" get pvc -l app.kubernetes.io/managed-by=kubespawner -o name | grep -q . || fail "culling removed the home volume"

step "uninstall removes servers and homes"
c start bob small scipy 600 >/dev/null
kill "$pf" 2>/dev/null; pf=
helm uninstall "$rel" -n "$ns" --wait --timeout 6m >/dev/null || fail "uninstall"
left=$(kubectl -n "$ns" get pods,pvc -l app.kubernetes.io/instance=$rel -o name)
[ -z "$left" ] || fail "left behind after uninstall: $left"
left=$(kubectl -n "$ns" get all,pvc,role,rolebinding,sa,cronjob,netpol,cm -o name | grep -v -E 'serviceaccount/default$|configmap/kube-root-ca.crt$' || true)
[ -z "$left" ] || fail "objects left in the namespace: $left"
echo "PASS"
