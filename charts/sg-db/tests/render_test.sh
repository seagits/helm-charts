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
# --- backups ---
grep -q '"helm.sh/hook": post-install' <<<"$pg" || fail "first-backup post-install hook (also forces Tier B)"
grep -q '"helm.sh/hook": post-install' <<<"$(render --set backup.firstBackup=false)" && fail "firstBackup=false must drop the post-install hook"
grep -q '"helm.sh/hook": pre-delete' <<<"$pg" || fail "final-backup pre-delete hook"
grep -q 'kind: CronJob' <<<"$pg" || fail "nightly CronJob"
grep -q 'schedule: "0 3 \* \* \*"' <<<"$pg" || fail "default schedule"
grep -q 'failedJobsHistoryLimit: 3' <<<"$pg" || fail "keep failed nightly jobs"
grep -A3 'name: MODE' <<<"$pg" | grep -q 'value: "final"' || fail "final mode env"
nodel=$(render --set backup.onDelete=false)
grep -q '"helm.sh/hook": pre-delete' <<<"$nodel" && fail "onDelete=false must drop the pre-delete hook"
grep -q 'pg_dump' <<<"$pg" || fail "postgres dump command"
grep -q 'mysqldump' <<<"$my" || fail "mysql dump command"
grep -q 'name: AWS_ENDPOINT_URL' <<<"$pg" && fail "endpoint env must be absent by default"
grep -q 'name: AWS_ENDPOINT_URL' <<<"$(render --set backup.endpointUrl=http://minio:9000)" || fail "endpoint env for tests"
if helm template db1 "$chart" "${base[@]}" --set backup.bucket= >/dev/null 2>&1; then fail "empty backup bucket accepted"; fi
grep -q 'secretRef: { name: minio-creds }' <<<"$(render --set backup.extraEnvFromSecret=minio-creds)" || fail "test env secret"
grep -q 'envFrom' <<<"$pg" && fail "envFrom must be absent by default"
# hooks must finish inside the worker's 600s Helm/Job window (SQS visibility 900s): 540s cap
grep -B2 -A40 'name: db1-backup-final' <<<"$pg" | grep -q 'activeDeadlineSeconds: 540' || fail "final hook deadline 540s"
grep -B2 -A40 'name: db1-backup-first' <<<"$pg" | grep -q 'activeDeadlineSeconds: 540' || fail "first hook deadline 540s"
grep -A30 'kind: CronJob' <<<"$pg" | grep -q 'activeDeadlineSeconds: 3600' || fail "nightly keeps 3600s"
# --- backup prefix (backup destination spec §6) ---
grep -q 'name: PREFIX, value: "backups/"' <<<"$pg" || fail "default backup prefix env"
cust=$(render --set backup.prefix='seagit-backups/db1/')
grep -q 'name: PREFIX, value: "seagit-backups/db1/"' <<<"$cust" || fail "custom backup prefix env"
grep -q 's3://${BUCKET}/backups/' <<<"$pg" && fail "upload.sh still hard-codes backups/"
for bad in '' 'nofolder' '/abs/' 'a/../b/' 'a/*/' 'a//' './'; do
  if render --set "backup.prefix=$bad" >/dev/null 2>&1; then fail "bad backup.prefix accepted: '$bad'"; fi
done
# --- KMS key for uploads (review I2): the user-named key is used to encrypt, not just allowed ---
grep -q 'name: KMS_KEY_ID, value: ""' <<<"$pg" || fail "default: no KMS key id (bucket default encryption)"
grep -q -- '--sse-kms-key-id "$KMS_KEY_ID"' <<<"$pg" || fail "upload.sh must pass the key when set"
kk=$(render --set backup.kmsKeyId=arn:aws:kms:us-east-1:111122223333:key/abcd-1234)
grep -q 'name: KMS_KEY_ID, value: "arn:aws:kms:us-east-1:111122223333:key/abcd-1234"' <<<"$kk" || fail "kmsKeyId env"
if render --set backup.kmsKeyId=not-an-arn >/dev/null 2>&1; then fail "bad kmsKeyId accepted"; fi
# --- priority class (staging 2026-10-02: a priority-0 DB pod was preempted by system pods) ---
grep -q 'priorityClassName' <<<"$pg" && fail "default must not set a priorityClassName"
pc=$(render --set priorityClassName=seagit-stateful)
grep -A40 'kind: StatefulSet' <<<"$pc" | grep -q 'priorityClassName: seagit-stateful' || fail "StatefulSet priorityClassName"
echo "render_test: OK"
