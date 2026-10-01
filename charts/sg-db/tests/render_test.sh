#!/usr/bin/env bash
# Render assertions for sg-db (no cluster needed). Run from the repo root.
set -euo pipefail
chart=charts/sg-db
fail() { echo "FAIL: $1"; exit 1; }
base=(--set auth.adminPassword=adminpw --set auth.appPassword=apppw
      --set seagit.deploymentId=dep123 --set serviceAccount.name=k8s-code1-db1
      --set serviceAccount.roleArn=arn:aws:iam::111122223333:role/sgt-app-code1-db1
      --set backup.bucket=env-db-abc123 --set backup.region=us-east-1)
render() { helm template db1 "$chart" -n apps "${base[@]}" "$@"; }

# --- engine x reach ---
pg=$(render --set engine=postgres)
grep -q 'image: "postgres:17"' <<<"$pg" || fail "postgres image"
grep -q 'containerPort: 5432' <<<"$pg" || fail "postgres port"
grep -q 'kind: ConfigMap' <<<"$pg" && grep -q 'name: db1-initdb' <<<"$pg" || fail "postgres initdb configmap"
grep -q 'apppw' <<<"$(grep -A40 'name: db1-initdb' <<<"$pg")" && fail "password leaked into initdb ConfigMap"
my=$(render --set engine=mysql)
grep -q 'image: "mysql:8.4"' <<<"$my" || fail "mysql image"
grep -q 'containerPort: 3306' <<<"$my" || fail "mysql port"
grep -q 'name: db1-initdb' <<<"$my" && fail "mysql must not render the postgres initdb"
grep -q 'name: MYSQL_USER' <<<"$my" || fail "mysql app user env"

grep -q 'name: db1-vpc' <<<"$pg" && fail "reach=cluster must not render the vpc service"
vpc=$(render --set reach=vpc)
grep -q 'name: db1-vpc' <<<"$vpc" || fail "vpc service"
grep -q 'service.beta.kubernetes.io/aws-load-balancer-scheme: internal' <<<"$vpc" || fail "internal scheme"
grep -q 'seagit.io/report-address: "true"' <<<"$vpc" || fail "report-address label"

# --- labels the platform relies on ---
grep -q 'seagit.io/deployment: dep123' <<<"$pg" || fail "owner label on StatefulSet (stop/start)"
grep -A6 'volumeClaimTemplates' <<<"$pg" | grep -q 'app.kubernetes.io/instance: db1' || fail "PVC instance label (destroy deletes PVCs by it)"
grep -q 'storageClassName: ebs-csi-slow-del' <<<"$pg" || fail "storage class"
grep -q 'key: node.kubernetes.io/lifecycle' <<<"$pg" || fail "off-spot affinity"
grep -q 'eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/sgt-app-code1-db1' <<<"$pg" || fail "IRSA annotation"
grep -q 'name: k8s-code1-db1' <<<"$pg" || fail "service account name"

# --- validation ---
if helm template db1 "$chart" --set engine=oracle "${base[@]}" >/dev/null 2>&1; then fail "bad engine accepted"; fi
if helm template db1 "$chart" --set auth.appPassword= --set auth.adminPassword=x >/dev/null 2>&1; then fail "empty app password accepted"; fi
echo "render_test: OK"
