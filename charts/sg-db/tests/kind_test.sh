#!/usr/bin/env bash
# Integration test on a throwaway kind cluster with an S3 stand-in (SeaweedFS). Run from the repo root.
# Needs: kind, kubectl, helm, docker. Deletes the cluster on exit.
set -euo pipefail
chart=charts/sg-db; ns=dbtest; cl=sgdb-test
fail() { echo "FAIL: $1"; exit 1; }
kind create cluster --name "$cl" >/dev/null
trap 'kind delete cluster --name "$cl" >/dev/null' EXIT
kubectl create ns "$ns" >/dev/null
# A new namespace's default ServiceAccount appears a moment later; pods are refused until it does.
until kubectl -n "$ns" get sa default >/dev/null 2>&1; do sleep 1; done

# S3 stand-in: SeaweedFS (any credentials when unconfigured). minio/minio and minio/mc are no longer
# pullable anonymously (2026-10), and adobe/s3mock drops aws-cli v2 uploads (EOF in its Tomcat).
kubectl -n "$ns" run s3 --image=chrislusf/seaweedfs:latest --port=8333 --command -- weed server -s3 -s3.port=8333 -dir=/data >/dev/null
kubectl -n "$ns" expose pod s3 --port=8333 >/dev/null
kubectl -n "$ns" wait --for=condition=Ready pod/s3 --timeout=300s >/dev/null
awsrun() {
  kubectl -n "$ns" run "aws-$RANDOM" --rm -i --restart=Never --image=public.ecr.aws/aws-cli/aws-cli:2.27.0 \
    --env=AWS_ACCESS_KEY_ID=k --env=AWS_SECRET_ACCESS_KEY=k --env=AWS_REGION=us-east-1 \
    --env=AWS_ENDPOINT_URL=http://s3:8333 -- "$@" 2>/dev/null
}
# the S3 port opens a few seconds after the pod is Ready
for i in $(seq 30); do awsrun s3 mb s3://backups-test | grep -q make_bucket && break; sleep 3; done
s3ls() { awsrun s3 ls --recursive s3://backups-test/backups/; }

common=(-n "$ns" --set auth.adminPassword=adminpw --set auth.appPassword=apppw
  --set backup.bucket=backups-test --set backup.region=us-east-1
  --set backup.endpointUrl=http://s3:8333 --set backup.extraEnvFromSecret=s3-creds
  --set storage.storageClass=standard --set avoidSpot=false --set storage.size=1Gi)
# aws-cli in the upload container reads static creds from env for the S3 stand-in (IRSA in real clusters).
kubectl -n "$ns" create secret generic s3-creds --from-literal=AWS_ACCESS_KEY_ID=k --from-literal=AWS_SECRET_ACCESS_KEY=k >/dev/null

for engine in postgres mysql; do
  rel="db-$engine"
  helm install "$rel" "$chart" "${common[@]}" --set engine="$engine" --wait --timeout 6m \
    || fail "$engine install (post-install backup hook)"
  objs=$(s3ls)
  grep -q '\.sql\.gz' <<<"$objs" || fail "$engine: no first backup object"
  grep -q '_status.json' <<<"$objs" || fail "$engine: no status object"

  # app user cannot reach another database
  if [ "$engine" = postgres ]; then
    # init revokes CONNECT on every database that exists at first start (postgres, the app db)
    if kubectl -n "$ns" exec "$rel-0" -- env PGPASSWORD=apppw psql -h 127.0.0.1 -U app -d postgres -c 'select 1' >/dev/null 2>&1; then
      fail "postgres: app user connected to the 'postgres' database"; fi
    # a database an admin creates LATER gets Postgres's default PUBLIC connect, but its data stays
    # the admin's: the app user cannot read it
    kubectl -n "$ns" exec "$rel-0" -- psql -U postgres -c "CREATE DATABASE other" >/dev/null
    kubectl -n "$ns" exec "$rel-0" -- psql -U postgres -d other -c "CREATE TABLE secret_t(x int); INSERT INTO secret_t VALUES (1)" >/dev/null
    if kubectl -n "$ns" exec "$rel-0" -- env PGPASSWORD=apppw psql -h 127.0.0.1 -U app -d other -c 'select * from secret_t' >/dev/null 2>&1; then
      fail "postgres: app user read another database's table"; fi
    kubectl -n "$ns" exec "$rel-0" -- env PGPASSWORD=apppw psql -h 127.0.0.1 -U app -d app -c 'create table t(x int)' >/dev/null || fail "postgres: app user cannot use its db"
  else
    kubectl -n "$ns" exec "$rel-0" -- sh -c 'mysql -uroot -padminpw -e "CREATE DATABASE other"' >/dev/null
    if kubectl -n "$ns" exec "$rel-0" -- sh -c 'mysql -uapp -papppw -e "use other"' >/dev/null 2>&1; then
      fail "mysql: app user reached database 'other'"; fi
  fi

  # final backup gates uninstall: break the dump (stop the database), uninstall must fail
  kubectl -n "$ns" scale statefulset "$rel" --replicas=0 >/dev/null
  kubectl -n "$ns" wait --for=delete pod/"$rel-0" --timeout=120s >/dev/null || true
  if helm uninstall "$rel" -n "$ns" --wait --timeout 3m >/dev/null 2>&1; then
    fail "$engine: uninstall succeeded with the database down (final backup must block it)"; fi
  # Delete anyway (spec §4.4): the release is now "uninstalling" after the failed hook; the worker
  # uninstalls with --no-hooks once the values say backup.onDelete=false. Prove that path works.
  helm uninstall "$rel" -n "$ns" --no-hooks --wait --timeout 3m >/dev/null || fail "$engine: delete-anyway (--no-hooks) uninstall"
  kubectl -n "$ns" delete pvc -l app.kubernetes.io/instance="$rel" --wait=false >/dev/null
done
echo "kind_test: OK"
