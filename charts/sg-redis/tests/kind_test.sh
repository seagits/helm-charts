#!/usr/bin/env bash
# Integration test on a throwaway kind cluster with an S3 stand-in (SeaweedFS). Run from the repo root.
# Needs: kind, kubectl, helm, docker, openssl. Deletes the cluster on exit (KEEP=1 keeps it).
set -euo pipefail
chart=charts/sg-redis; ns=redistest; cl=${CLUSTER:-sgredis-test}
fail() { echo "FAIL: $1"; exit 1; }
helm dependency build "$chart" >/dev/null
kind create cluster --name "$cl" >/dev/null
[ "${KEEP:-}" = 1 ] || trap 'kind delete cluster --name "$cl" >/dev/null' EXIT
kubectl config use-context "kind-$cl" >/dev/null
kubectl create ns "$ns" >/dev/null
until kubectl -n "$ns" get sa default >/dev/null 2>&1; do sleep 1; done

kubectl -n "$ns" run s3 --image=chrislusf/seaweedfs:latest --port=8333 --command -- weed server -s3 -s3.port=8333 -dir=/data >/dev/null
kubectl -n "$ns" expose pod s3 --port=8333 >/dev/null
kubectl -n "$ns" wait --for=condition=Ready pod/s3 --timeout=300s >/dev/null
awsrun() {
  kubectl -n "$ns" run "aws-$RANDOM" --rm -i --restart=Never --image=public.ecr.aws/aws-cli/aws-cli:2.27.0 \
    --env=AWS_ACCESS_KEY_ID=k --env=AWS_SECRET_ACCESS_KEY=k --env=AWS_REGION=us-east-1 \
    --env=AWS_ENDPOINT_URL=http://s3:8333 -- "$@" 2>/dev/null
}
for i in $(seq 30); do awsrun s3 mb s3://backups-test | grep -c >/dev/null make_bucket && break; sleep 3; done
s3ls() { awsrun s3 ls --recursive "s3://backups-test/$1/"; }
kubectl -n "$ns" create secret generic s3-creds --from-literal=AWS_ACCESS_KEY_ID=k --from-literal=AWS_SECRET_ACCESS_KEY=k >/dev/null

PW=kindtestpassword0123456789
common=(-n "$ns" --set auth.password=$PW --set backup.bucket=backups-test --set backup.region=us-east-1
  --set backup.endpointUrl=http://s3:8333 --set backup.extraEnvFromSecret=s3-creds
  --set storage.storageClass=standard --set avoidSpot=false --set storage.size=1Gi)

for engine in valkey redis; do
  rel="r-$engine"; cli="$engine-cli"
  helm install "$rel" "$chart" "${common[@]}" --set engine="$engine" --set backup.prefix="$rel/" --wait --timeout 6m \
    || fail "$engine install (post-install backup hook)"
  ex() { kubectl -n "$ns" exec "$rel-0" -c redis -- "$@"; }
  objs=$(s3ls "$rel")
  grep -q -E '[0-9]{8}T[0-9]{6}Z\.rdb\.gz' <<<"$objs" || fail "$engine: no first backup object ($objs)"
  grep -q '_status.json' <<<"$objs" || fail "$engine: no status object"

  # AUTH is required; the password works
  out=$(ex env -u REDISCLI_AUTH -u VALKEYCLI_AUTH "$cli" -p 6379 ping 2>&1 || true)
  grep -q NOAUTH <<<"$out" || fail "$engine: ping without a password was not refused ($out)"
  [ "$(ex "$cli" -p 6379 set k1 v1)" = OK ] || fail "$engine: set"
  [ "$(ex "$cli" -p 6379 get k1)" = v1 ] || fail "$engine: get"
  ex "$cli" -p 6379 config get appendonly | grep -c >/dev/null yes || fail "$engine: AOF off"
  ex "$cli" -p 6379 config get maxmemory | grep -c >/dev/null 100663296 || fail "$engine: maxmemory not 96mb"
  # password is not on the server's command line
  ex sh -c 'cat /proc/1/cmdline | tr "\0" " "' | grep -c >/dev/null "$PW" && fail "$engine: password on the command line"

  # data survives a pod restart (AOF on the volume)
  kubectl -n "$ns" delete pod "$rel-0" --wait=true >/dev/null
  kubectl -n "$ns" wait --for=condition=Ready pod/"$rel-0" --timeout=180s >/dev/null
  [ "$(ex "$cli" -p 6379 get k1)" = v1 ] || fail "$engine: data lost on restart"

  # nightly job path (same pod spec): run once from the CronJob
  kubectl -n "$ns" create job "$rel-manual" --from=cronjob/"$rel-backup" >/dev/null
  kubectl -n "$ns" wait --for=condition=complete job/"$rel-manual" --timeout=180s >/dev/null || fail "$engine: nightly backup job"

  # final backup on uninstall
  helm uninstall "$rel" -n "$ns" --wait --timeout 3m >/dev/null || fail "$engine: uninstall (final backup)"
  fin=$(s3ls "$rel"); grep -q "final-.*\.rdb\.gz" <<<"$fin" || fail "$engine: no final backup object ($fin)"
  kubectl -n "$ns" delete pvc -l app.kubernetes.io/instance="$rel" --wait=false >/dev/null
  echo "kind_test: $engine OK"
done

# --- public reach: TLS through the Service on 6379, plain 6379 on the pod, live certificate reload ---
rel=rp; svc="$rel-public.$ns.svc.cluster.local"; tmp=$(mktemp -d)
mkcert() {
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$1" -addext "subjectAltName=DNS:$svc" \
    -keyout "$tmp/tls.key" -out "$tmp/tls.crt" >/dev/null 2>&1
  kubectl -n "$ns" create secret tls rp-tls --cert="$tmp/tls.crt" --key="$tmp/tls.key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}
mkcert first
# kind has no load balancer: install without --wait (Helm would wait for an address forever)
helm install "$rel" "$chart" "${common[@]}" --set reach=public --set public.leafHost=rp-kind.example.com \
  --set public.tlsSecret=rp-tls --set public.allowedCidrs=10.0.0.0/8 \
  --set backup.firstBackup=false --set backup.onDelete=false >/dev/null || fail "public install"
kubectl -n "$ns" rollout status statefulset/"$rel" --timeout=180s >/dev/null || fail "public: pod not ready"
kubectl -n "$ns" get svc "$rel-public" -o jsonpath='{.spec.loadBalancerSourceRanges}' | grep -c >/dev/null '10.0.0.0/8' || fail "public: sourceRanges"
sx() { kubectl -n "$ns" exec "$rel-0" -c tls-reload -- "$@"; }
# the Service endpoint routes a few seconds after the pod is Ready
for i in $(seq 20); do [ "$(sx valkey-cli --tls --cacert /tls/tls.crt -h "$svc" -p 6379 ping 2>/dev/null)" = PONG ] && break; sleep 3; done
[ "$(sx valkey-cli --tls --cacert /tls/tls.crt -h "$svc" -p 6379 ping)" = PONG ] || fail "public: TLS through the Service"
if sx valkey-cli -h "$svc" -p 6379 ping 2>/dev/null | grep -c >/dev/null PONG; then fail "public: plaintext accepted on the public port"; fi
[ "$(kubectl -n "$ns" exec "$rel-0" -c redis -- valkey-cli -p 6379 ping)" = PONG ] || fail "public: in-cluster plain port"
old=$(sx sh -c 'md5sum /tls/tls.crt' | cut -d' ' -f1)
mkcert second
echo "waiting for the kubelet to swap the secret and the sidecar to reload (up to ~3 min)"
for i in $(seq 36); do
  kubectl -n "$ns" logs "$rel-0" -c tls-reload 2>/dev/null | grep -c >/dev/null 'tls certificate reloaded' && break; sleep 5
done
kubectl -n "$ns" logs "$rel-0" -c tls-reload | grep -c >/dev/null 'tls certificate reloaded' || fail "public: certificate not reloaded"
new=$(sx sh -c 'md5sum /tls/tls.crt' | cut -d' ' -f1)
[ "$old" != "$new" ] || fail "public: mounted certificate did not change"
# the NEW cert (and only it) now verifies the server
[ "$(sx valkey-cli --tls --cacert /tls/tls.crt -h "$svc" -p 6379 ping)" = PONG ] || fail "public: TLS after reload"
helm uninstall "$rel" -n "$ns" --wait --timeout 3m >/dev/null
echo "kind_test: public OK"
echo "kind_test: OK"
