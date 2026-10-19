#!/usr/bin/env bash
# The hub on a cluster's SHARED ENTRANCE (sg-notebooks 0.1.6, public.exposure=shared), end to end:
# nginx, or Envoy through the Gateway API (the platform's route sync turns the chart's Ingress into
# an HTTPRoute + SecurityPolicy). Run on a cluster-worker gateway rig (hack/gateway-rig/up.sh):
#   nginx:   KC=<rig kubeconfig> ENTRANCE=nginx ./ingress_test.sh
#   Gateway: KC=<rig kubeconfig> ENTRANCE=gateway GWMIG=<gatewaymig binary> ./ingress_test.sh
# The client runs in a container on the kind Docker network (macOS cannot route to it) and reaches
# the hub by its real names through the entrance.
# Proves: sign-in (and refusal), logout, a kernel idle past the entrance's default timeout, a
# terminal, a 5 MiB upload, Allowed IPs (allowed 200 / other address 403), and that the timeout,
# upload-size and allowlist settings really take effect (negative controls).
set -euo pipefail
chart=charts/sg-notebooks; ns=nbing; rel=nb1
here=$(cd "$(dirname "$0")" && pwd)
: "${KC:?KC=<kubeconfig of the rig>}" "${ENTRANCE:?ENTRANCE=nginx|gateway}"
fail() { echo "FAIL: $1"; exit 1; }
step() { echo "--- $(date +%H:%M:%S) $1"; }
k() { kubectl --kubeconfig "$KC" "$@"; }
h() { helm --kubeconfig "$KC" "$@"; }
PASSES=0; pass() { PASSES=$((PASSES+1)); echo "PASS  $*"; }
host=nb1.rig.test; leaf=nb1-sgt-rig.rig.test
subnet=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+/[0-9]+$' | head -1)
[ -n "$subnet" ] || fail "no IPv4 subnet on the kind network"
case "$ENTRANCE" in
  nginx) IP=$(k -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}') ;;
  gateway) : "${GWMIG:?GWMIG=<gatewaymig binary>}"
    IP=$("$GWMIG" --kubeconfig "$KC" status | python3 -c 'import json,sys; print(json.load(sys.stdin).get("envoy_address",""))') ;;
  *) fail "ENTRANCE must be nginx or gateway" ;;
esac
[ -n "$IP" ] || fail "no entrance address"
echo "entrance $ENTRANCE at $IP; kind subnet $subnet"
sync_routes() { [ "$ENTRANCE" = gateway ] && "$GWMIG" --kubeconfig "$KC" --timeout 5m sync >/dev/null; return 0; }

ADMIN_PW=$(openssl rand -hex 24); USER_PW=$(openssl rand -hex 12); TOKEN=$(openssl rand -hex 32)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cat > "$work/values.yaml" <<EOF
public: { host: $host, leafHost: $leaf, tlsSecret: nb1-tls, certIssuer: selfsigned, allowedCidrs: "$subnet" }
seagit: { deploymentId: dep-rig }
serviceAccount: { name: k8s-rig-nb1, roleArn: "arn:aws:iam::111122223333:role/sgt-app-rig-nb1" }
jupyterhub:
  custom:
    auth: { type: password, admins: alice, allowedUsers: "bob", adminPassword: "$ADMIN_PW", userPassword: "$USER_PW" }
    sizes: small
    images: scipy
    avoidSpot: false
    bucket: env-nb-rig
    region: us-east-1
  hub:
    db: { pvc: { storageClassName: standard } }
    services: { kindtest: { api_token: "$TOKEN" } }
    loadRoles:
      kindtest: { services: [kindtest], scopes: [admin:users, admin:servers, access:servers, read:users] }
  singleuser:
    serviceAccountName: k8s-rig-nb1
    storage: { capacity: 1Gi, dynamic: { storageClass: standard } }
EOF
up() { h upgrade --install "$rel" "$chart" -n "$ns" -f "$work/values.yaml" "$@" --wait --timeout 10m >/dev/null; sync_routes; }
code() { docker run --rm --network kind curlimages/curl:8.10.1 -sk -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$host:443:$IP" "$@"; }
wait_code() { local want=$1 c=""; shift; for _ in $(seq 1 60); do c=$(code "$@"); [ "$c" = "$want" ] && return 0; sleep 3; done; echo "got $c" >&2; return 1; }
c() { docker run --rm --network kind --add-host "$host:$IP" -v "$here:/t:ro" -e HUB="https://$host" -e TOKEN="$TOKEN" node:22-alpine node /t/hub_client.mjs "$@"; }

step "install (shared entrance, Allowed IPs = the kind network)"
helm dependency build "$chart" >/dev/null
k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
up
k -n "$ns" wait --for=condition=Ready certificate/nb1-tls --timeout=180s >/dev/null || fail "certificate"
sync_routes
[ "$(k -n "$ns" get svc nb1-notebooks-proxy-public -o jsonpath='{.spec.type}')" = ClusterIP ] && pass "no load balancer of its own"
if [ "$ENTRANCE" = gateway ]; then
  [ "$(k -n "$ns" get httproute -o name | wc -l | tr -d ' ')" -ge 1 ] && pass "route sync made an HTTPRoute from the chart's Ingress" || fail "no HTTPRoute"
  [ "$(k -n "$ns" get securitypolicy -o name | wc -l | tr -d ' ')" -ge 1 ] && pass "Allowed IPs became a SecurityPolicy" || fail "no SecurityPolicy"
fi
wait_code 200 "https://$host/hub/login" && pass "hub login page 200 through $ENTRANCE" || fail "hub not reachable through $ENTRANCE"
wait_code 200 --resolve "$leaf:443:$IP" "https://$leaf/hub/login" && pass "per-cluster name 200" || fail "leaf host"

step "sign-in, logout"
[ "$(c login alice "$ADMIN_PW")" = ok ] && pass "admin signs in" || fail "admin sign-in"
[ "$(c login bob wrong-password-123)" = refused ] && pass "wrong password refused" || fail "wrong password accepted"
loc=$(docker run --rm --network kind curlimages/curl:8.10.1 -sk -o /dev/null -w '%{redirect_url}' --resolve "$host:443:$IP" "https://$host/hub/logout")
grep -q '/hub/login' <<<"$loc" && pass "logout returns to the sign-in page" || fail "logout went to $loc"

step "server: kernel idle past the default timeout, terminal, upload"
c start bob small scipy 900 >/dev/null && pass "bob's server started through $ENTRANCE"
[ "$(c run bob 'print(6*7)')" = 42 ] && pass "kernel runs code" || fail "kernel"
# ingress-nginx and Envoy close an idle upstream read after 60 s by default
[ "$(c idle bob 90)" = 42 ] && pass "kernel websocket idle 90 s, still works (timeout 3600)" || fail "idle kernel websocket closed"
[ "$(c term bob)" = term-42 ] && pass "terminal round trip" || fail "terminal"
[ "$(c upload bob 5)" = 201 ] && pass "5 MiB upload (default limit is 1 MiB)" || fail "upload refused"

step "negative controls: the settings take effect"
up --set public.timeoutSeconds=20 --reuse-values
sleep 5
if c idle bob 40 >/dev/null 2>&1; then fail "idle 40 s survived timeoutSeconds=20: the timeout setting does nothing"; else pass "timeoutSeconds=20 closes a 40 s idle websocket"; fi
up --set public.timeoutSeconds=3600 --set public.maxUploadSize=1m --reuse-values
sleep 5
[ "$(c upload bob 5)" = 413 ] && pass "maxUploadSize=1m refuses 5 MiB (413)" || fail "upload size setting does nothing"
up --set public.maxUploadSize=512m --set-string public.allowedCidrs=203.0.113.7/32 --reuse-values
wait_code 403 "https://$host/hub/login" && pass "Allowed IPs without the client's network → 403" || fail "allowlist not enforced"
up --set-string "public.allowedCidrs=$subnet" --reuse-values
wait_code 200 "https://$host/hub/login" && pass "client's network allowed again → 200" || fail "allowlist restore"
up --set-string public.allowedCidrs= --reuse-values
wait_code 200 "https://$host/hub/login" && pass "no Allowed IPs → anyone" || fail "open hub"

step "cleanup"
c stop bob >/dev/null || true
h uninstall "$rel" -n "$ns" --wait --timeout 6m >/dev/null
sync_routes
k delete namespace "$ns" --wait=false >/dev/null
echo; echo "ALL $PASSES CHECKS PASSED through $ENTRANCE"
