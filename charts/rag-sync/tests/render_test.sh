#!/usr/bin/env bash
# Render assertions for rag-sync (no cluster needed). Run from the repo root.
set -euo pipefail
chart=charts/rag-sync
out=$(helm template t "$chart" \
  --set ragApiUrl=http://api.apps.svc.cluster.local:8000 \
  --set serviceTokenSecret.name=rag-secrets \
  --set-json 'sources=[{"id":"docs","bucket":"b1","prefix":"kb/","mode":"both","schedule":"*/30 * * * *","roleArn":"arn:aws:iam::1:role/r-docs","mirrorDeletes":true},{"id":"faq","bucket":"b2","mode":"once"}]')
fail() { echo "FAIL: $1"; exit 1; }

# --- Task 13 helpers: import_now/sync fields + events sync (no yq available; grep/awk instead) ---
# common_args: a minimal, valid base (existingServiceAccount so ServiceAccount never renders and
# these kind-set assertions stay simple).
common_args=(--set ragApiUrl=http://x --set serviceTokenSecret.name=s --set existingServiceAccount=k8s-c-abc)

# expect_kinds LABEL SOURCES_JSON_ARRAY EXPECTED_KINDS [EXTRA_HELM_ARGS...]
# Renders with `sources` set to SOURCES_JSON_ARRAY (a JSON array literal) and asserts the sorted,
# de-duplicated set of `kind:` values in the output exactly matches EXPECTED_KINDS (space-separated).
expect_kinds() {
  local label="$1" src="$2" expected="$3"; shift 3
  local out
  if ! out=$(helm template t "$chart" "${common_args[@]}" --set-json "sources=$src" "$@" 2>&1); then
    fail "$label: expected render to succeed, got: $out"
  fi
  local got want
  got=$(grep '^kind: ' <<<"$out" | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ *$//')
  want=$(tr ' ' '\n' <<<"$expected" | sort -u | tr '\n' ' ' | sed 's/ *$//')
  [ "$got" = "$want" ] || fail "$label: want kinds [$want] got [$got]: $out"
}

# expect_fail LABEL SOURCES_JSON_ARRAY MESSAGE_SUBSTRING
# Asserts the render fails (non-zero exit) and stderr/stdout contains MESSAGE_SUBSTRING.
expect_fail() {
  local label="$1" src="$2" msg="$3"
  local out
  if out=$(helm template t "$chart" "${common_args[@]}" --set-json "sources=$src" 2>&1); then
    fail "$label: expected render to fail, it rendered OK: $out"
  fi
  grep -qF "$msg" <<<"$out" || fail "$label: expected error to mention '$msg', got: $out"
}

# expect_env LABEL SOURCES_JSON_ARRAY ENV_VAR_NAME VALUE_SUBSTRING
# Asserts some `- name: ENV_VAR_NAME` block's `value:` line contains VALUE_SUBSTRING.
expect_env() {
  local label="$1" src="$2" var="$3" val="$4"; shift 4 || true
  local out
  if ! out=$(helm template t "$chart" "${common_args[@]}" --set-json "sources=$src" "$@" 2>&1); then
    fail "$label: expected render to succeed, got: $out"
  fi
  grep -A1 "name: $var$" <<<"$out" | grep -qF "$val" || fail "$label: expected $var to contain '$val', got: $out"
}

# legacy modes keep rendering exactly as 0.2.x (both the original mode vocabulary this chart
# shipped with -- once/schedule/both -- and the once/cron/once_cron spelling)
expect_kinds "legacy once"      '[{"id":"kb","bucket":"b","mode":"once"}]'                                    "Job"
expect_kinds "legacy cron"      '[{"id":"kb","bucket":"b","mode":"cron","schedule":"0 2 * * *"}]'             "CronJob"
expect_kinds "legacy once_cron" '[{"id":"kb","bucket":"b","mode":"once_cron","schedule":"0 2 * * *"}]'        "Job CronJob"
expect_kinds "legacy schedule"  '[{"id":"kb","bucket":"b","mode":"schedule","schedule":"0 2 * * *"}]'         "CronJob"
expect_kinds "legacy both"      '[{"id":"kb","bucket":"b","mode":"both","schedule":"0 2 * * *"}]'             "Job CronJob"

# new import_now/sync fields
expect_kinds "import+events_sweep" '[{"id":"kb","bucket":"b","import_now":true,"sync":"events_sweep","schedule":"0 2 * * *"}]' \
  "Job CronJob Deployment" --set eventsQueueUrl=https://q
expect_kinds "events only" '[{"id":"kb","bucket":"b","import_now":false,"sync":"events"}]' \
  "Deployment" --set eventsQueueUrl=https://q
expect_fail "nothing to do" '[{"id":"kb","bucket":"b","import_now":false,"sync":"none"}]' "would never be indexed"
expect_fail "unknown sync value" '[{"id":"kb","bucket":"b","import_now":true,"sync":"whenever"}]' "unknown sync"
expect_fail "events with no queue configured" '[{"id":"kb","bucket":"b","import_now":false,"sync":"events"}]' \
  "neither eventsQueueUrl nor uploads.queueUrl is set"
expect_env "role + region reach the pod" \
  '[{"id":"kb","bucket":"b","import_now":true,"sync":"none","region":"eu-west-1","role_arn":"arn:aws:iam::9:role/r"}]' \
  'SOURCE_JSON' '\"role_arn\":\"arn:aws:iam::9:role/r\"'
expect_env "region reaches SOURCE_JSON too" \
  '[{"id":"kb","bucket":"b","import_now":true,"sync":"none","region":"eu-west-1","role_arn":"arn:aws:iam::9:role/r"}]' \
  'SOURCE_JSON' '\"region\":\"eu-west-1\"'
expect_env "events source lands in SOURCES_JSON" \
  '[{"id":"kb","bucket":"b","import_now":false,"sync":"events"}]' \
  'SOURCES_JSON' '\"id\":\"kb\"' --set eventsQueueUrl=https://q

# --- fix round 1 findings ---
# CRITICAL: a bare legacy source (no mode/sync/import_now key at all) must default to "once"
# (matching 0.2.x's `.mode | default "once"`), i.e. Job only -- NOT "once_cron"/CronJob+Job.
expect_kinds "bare legacy source defaults to once" '[{"id":"docs","bucket":"b1"}]' "Job"
# IMPORTANT: a source is "new-style" as soon as it has `sync` OR `import_now` -- either alone
# opts it in. New-style with `sync` absent defaults `sync` to "events_sweep".
expect_kinds "import_now alone, false: no Job, sync defaults events_sweep" \
  '[{"id":"kb","bucket":"b","import_now":false,"schedule":"0 2 * * *"}]' \
  "CronJob Deployment" --set eventsQueueUrl=https://q
expect_kinds "import_now alone, true: no sync given, sync defaults events_sweep" \
  '[{"id":"kb","bucket":"b","import_now":true,"schedule":"0 2 * * *"}]' \
  "Job CronJob Deployment" --set eventsQueueUrl=https://q
[ "$(grep -c '^kind: Job$' <<<"$out")" = 2 ] || fail "want 2 Jobs (docs+faq once)"
[ "$(grep -c '^kind: CronJob$' <<<"$out")" = 1 ] || fail "want 1 CronJob (docs)"
[ "$(grep -c '^kind: ServiceAccount$' <<<"$out")" = 2 ] || fail "want 2 SAs per source"
grep -q 'concurrencyPolicy: Forbid' <<<"$out" || fail "CronJob must forbid overlap"
grep -q 'eks.amazonaws.com/role-arn: arn:aws:iam::1:role/r-docs' <<<"$out" || fail "IRSA annotation"
grep -q '\\"mirror_deletes\\":true' <<<"$out" || fail "SOURCE_JSON must carry mirror_deletes"
grep -q 'helm.sh/hook' <<<"$out" && fail "no hooks allowed (Tier A)"
[ -z "$(helm template t "$chart")" ] || [ "$(helm template t "$chart" | grep -c '^kind:')" = 0 ] || fail "no sources => no objects"
shared=$(helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s --set existingServiceAccount=k8s-c-abc \
  --set-json 'sources=[{"id":"docs","bucket":"b1","mode":"once"}]')
[ "$(grep -c '^kind: ServiceAccount$' <<<"$shared")" = 0 ] || fail "existingServiceAccount => no SAs rendered"
grep -q 'serviceAccountName: k8s-c-abc' <<<"$shared" || fail "pods must use existingServiceAccount"
# Test: invalid source id must fail
helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s \
  --set-json 'sources=[{"id":"My_Source","bucket":"b1","mode":"once"}]' >/dev/null 2>&1 && fail "invalid id My_Source should fail"
# Test: Job name includes content hash (8 hex chars)
grep -q 'name: t-once-docs-[0-9a-f]\{8\}' <<<"$out" || fail "Job name must include 8-char content hash"
# Test: changing image tag changes Job name hash
out2=$(helm template t "$chart" \
  --set ragApiUrl=http://api.apps.svc.cluster.local:8000 \
  --set serviceTokenSecret.name=rag-secrets \
  --set image.tag=0.2.0 \
  --set-json 'sources=[{"id":"docs","bucket":"b1","prefix":"kb/","mode":"both","schedule":"*/30 * * * *","roleArn":"arn:aws:iam::1:role/r-docs","mirrorDeletes":true},{"id":"faq","bucket":"b2","mode":"once"}]')
job_name_1=$(grep 'name: t-once-docs-' <<<"$out" | head -1 | sed 's/.*name: //;s/ *$//')
job_name_2=$(grep 'name: t-once-docs-' <<<"$out2" | head -1 | sed 's/.*name: //;s/ *$//')
[ "$job_name_1" != "$job_name_2" ] || fail "changing image.tag should change Job name hash"

# --- I4: "uploads" is reserved by rag-api for the public upload path ---
err=$(helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s \
  --set-json 'sources=[{"id":"uploads","bucket":"b1","mode":"once"}]' 2>&1) && fail "source id uploads should fail"
grep -q 'reserved' <<<"$err" || fail "uploads rejection needs a clear message, got: $err"

# --- I5: names fit k8s limits (Job <=63, CronJob <=52) and stay unique ---
rel=rag-release-name-20c                     # 20 chars
id40=$(printf 'a%.0s' $(seq 1 39))b          # 40 chars
id40b=$(printf 'a%.0s' $(seq 1 39))c         # 40 chars, differs only in the last char
[ "${#rel}" = 20 ] && [ "${#id40}" = 40 ] || fail "test setup: lengths"
long=$(helm template "$rel" "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s \
  --set-json "sources=[{\"id\":\"$id40\",\"bucket\":\"b1\",\"mode\":\"both\",\"schedule\":\"0 * * * *\"},{\"id\":\"$id40b\",\"bucket\":\"b1\",\"mode\":\"both\",\"schedule\":\"0 * * * *\"}]") \
  || fail "long release+id must render, not fail"
kind_names() { awk -v k="$2" '/^kind: /{kind=$2} kind==k && /^  name: /{print $2}' <<<"$1"; }
jobs=$(kind_names "$long" Job); crons=$(kind_names "$long" CronJob)
[ "$(wc -l <<<"$jobs" | tr -d ' ')" = 2 ] && [ "$(sort -u <<<"$jobs" | wc -l | tr -d ' ')" = 2 ] || fail "Job names must be unique: $jobs"
[ "$(wc -l <<<"$crons" | tr -d ' ')" = 2 ] && [ "$(sort -u <<<"$crons" | wc -l | tr -d ' ')" = 2 ] || fail "CronJob names must be unique: $crons"
while read -r n; do [ "${#n}" -le 63 ] || fail "Job name >63: $n"; grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' <<<"$n" || fail "Job name not DNS-1123: $n"; done <<<"$jobs"
while read -r n; do [ "${#n}" -le 52 ] || fail "CronJob name >52: $n"; grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' <<<"$n" || fail "CronJob name not DNS-1123: $n"; done <<<"$crons"
# every label value stays within 63
awk '/^ *labels:/{inl=1; ind=match($0,/[^ ]/); next} inl{ i=match($0,/[^ ]/); if (i<=ind) {inl=0} else { sub(/^[^:]*: */,""); gsub(/"/,""); if (length($0)>63) {print "LONG " $0} } }' <<<"$long" | grep -q LONG && fail "label value >63"
# short names are left as-is (no truncation hash appended)
grep -q 'name: t-cron-docs$' <<<"$out" || fail "short CronJob name must stay t-cron-docs"
# deterministic: same values => same names
long2=$(helm template "$rel" "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s \
  --set-json "sources=[{\"id\":\"$id40\",\"bucket\":\"b1\",\"mode\":\"both\",\"schedule\":\"0 * * * *\"},{\"id\":\"$id40b\",\"bucket\":\"b1\",\"mode\":\"both\",\"schedule\":\"0 * * * *\"}]")
[ "$jobs" = "$(kind_names "$long2" Job)" ] && [ "$crons" = "$(kind_names "$long2" CronJob)" ] || fail "names must be deterministic"

# --- I6: the Job-name hash covers the whole pod template ---
base_args=(--set ragApiUrl=http://x --set serviceTokenSecret.name=s --set-json 'sources=[{"id":"docs","bucket":"b1","mode":"once"}]')
jobname() { helm template t "$chart" "${base_args[@]}" "$@" | awk '/^kind: Job$/{k=1} k && /^  name: /{print $2; exit}'; }
n0=$(jobname)
[ "$n0" = "$(jobname)" ] || fail "identical values must keep the Job name stable"
[ "$n0" != "$(jobname --set awsRegion=eu-west-1)" ] || fail "awsRegion must change the Job name"
[ "$n0" != "$(jobname --set serviceTokenSecret.name=other)" ] || fail "serviceTokenSecret.name must change the Job name"
[ "$n0" != "$(jobname --set resources.limits.memory=2Gi)" ] || fail "resources must change the Job name"
[ "$n0" != "$(jobname --set existingServiceAccount=shared-sa)" ] || fail "existingServiceAccount must change the Job name"

# --- M10: hardened pod/container securityContext, /tmp emptyDir, activeDeadlineSeconds ---
for k in Job CronJob; do
  doc=$(awk -v k="$k" '/^---/{p=0} /^kind: /{p=($2==k)} p' <<<"$out")
  grep -q 'runAsNonRoot: true' <<<"$doc" || fail "$k: runAsNonRoot"
  grep -q 'runAsUser: 10001' <<<"$doc" || fail "$k: runAsUser 10001"
  grep -q 'type: RuntimeDefault' <<<"$doc" || fail "$k: seccompProfile RuntimeDefault"
  grep -q 'allowPrivilegeEscalation: false' <<<"$doc" || fail "$k: allowPrivilegeEscalation"
  grep -q 'readOnlyRootFilesystem: true' <<<"$doc" || fail "$k: readOnlyRootFilesystem"
  grep -A1 'drop:' <<<"$doc" | grep -q -- '- ALL' || fail "$k: capabilities drop ALL"
  grep -q 'mountPath: /tmp' <<<"$doc" || fail "$k: /tmp mount"
  grep -q 'emptyDir: {}' <<<"$doc" || fail "$k: /tmp emptyDir"
  grep -q 'activeDeadlineSeconds: 3600' <<<"$doc" || fail "$k: activeDeadlineSeconds default 3600"
done
helm template t "$chart" "${base_args[@]}" --set activeDeadlineSeconds=600 | grep -q 'activeDeadlineSeconds: 600' || fail "activeDeadlineSeconds must be a value"

helm lint "$chart" >/dev/null || fail "helm lint"

# --- P5 Task 6: ingest-uploads CronJob for the shared multi-cluster uploads bucket ---
# ingest-uploads (P5): bucket set => one extra CronJob, flagged, mirror deletes on
up=$(helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s \
  --set existingServiceAccount=k8s-c-abc --set uploads.bucket=dev-rag-a1b2c3)
[ "$(grep -c '^kind: CronJob$' <<<"$up")" = 1 ] || fail "uploads bucket => exactly one CronJob"
grep -q 'name: t-cron-uploads' <<<"$up" || fail "uploads CronJob name"
grep -q 'schedule: "\*/5 \* \* \* \*"' <<<"$up" || fail "default uploads schedule */5"
grep -q 'name: SYNC_UPLOADS' <<<"$up" || fail "uploads job must set SYNC_UPLOADS"
grep -q '\\"id\\":\\"uploads\\"' <<<"$up" || fail "SOURCE_JSON id uploads"
grep -q '\\"prefix\\":\\"uploads/\\"' <<<"$up" || fail "default prefix uploads/"
grep -q '\\"mirror_deletes\\":true' <<<"$up" || fail "uploads mirror deletes"
# no bucket => no uploads CronJob, and user sources still may not be named uploads
[ "$(helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s | grep -c 'cron-uploads')" = 0 ] || fail "no bucket => no uploads CronJob"
helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s \
  --set-json 'sources=[{"id":"uploads","bucket":"b1","mode":"once"}]' >/dev/null 2>&1 && fail "user source id uploads must still fail"
# user sources must NOT carry SYNC_UPLOADS
[ "$(grep -c 'SYNC_UPLOADS' <<<"$out")" = 0 ] || fail "user source jobs must not set SYNC_UPLOADS"
# uploads.bucket without existingServiceAccount must fail fast (no per-source SA named uploads exists)
helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s \
  --set uploads.bucket=dev-rag-a1b2c3 >/dev/null 2>&1 && fail "uploads.bucket requires existingServiceAccount"

# --- P5.1 Task 6: uploads-events consumer Deployment + hourly safety-net schedule ---
ev=$(helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s --set existingServiceAccount=k8s-c-abc \
  --set uploads.bucket=b-1 --set uploads.queueUrl=https://sqs.us-west-2.amazonaws.com/5/sgt-rag-d-c)
[ "$(grep -c '^kind: Deployment$' <<<"$ev")" = 1 ] || fail "queueUrl => one consumer Deployment"
grep -q 'name: t-uploads-events' <<<"$ev" || fail "consumer name"
grep -q '"rag_api.events"' <<<"$ev" || fail "consumer command"
grep -q 'value: "https://sqs.us-west-2.amazonaws.com/5/sgt-rag-d-c"' <<<"$ev" || fail "QUEUE_URL env"
grep -q 'serviceAccountName: k8s-c-abc' <<<"$ev" || fail "consumer uses rag-api SA"
grep -q 'schedule: "0 \* \* \* \*"' <<<"$ev" || fail "uploads CronJob becomes hourly safety net"
[ "$(helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s --set existingServiceAccount=k8s-c-abc --set uploads.bucket=b-1 | grep -c '^kind: Deployment$')" = 0 ] || fail "no queueUrl => no consumer"
helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s --set existingServiceAccount=k8s-c-abc \
  --set uploads.queueUrl=https://q >/dev/null 2>&1 && fail "queueUrl without bucket must fail"

# --- P5.1 Task 6 fix round 1: Deployment selector must not overlap Job/CronJob pods ---
combined=$(helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s --set existingServiceAccount=k8s-c-abc \
  --set uploads.bucket=b-1 --set uploads.queueUrl=https://sqs.us-west-2.amazonaws.com/5/sgt-rag-d-c \
  --set-json 'sources=[{"id":"docs","bucket":"b1","mode":"both","schedule":"0 * * * *"}]')
depdoc=$(awk '/^---/{p=0} /^kind: /{p=($2=="Deployment")} p' <<<"$combined")
[ "$(grep -c 'app.kubernetes.io/component: uploads-events' <<<"$depdoc")" = 2 ] || fail "Deployment selector+template need component=uploads-events (want 2 occurrences: selector.matchLabels + template.metadata.labels)"
for k in Job CronJob; do
  doc=$(awk -v k="$k" '/^---/{p=0} /^kind: /{p=($2==k)} p' <<<"$combined")
  grep -q 'app.kubernetes.io/component: uploads-events' <<<"$doc" && fail "$k pod template must not carry the uploads-events component label"
done

# --- final review C-C2: uploads.region / uploads.role_arn reach the uploads source (CronJob
# SOURCE_JSON and the events consumer's SOURCES_JSON) so an existing uploads bucket in another
# account/region is readable ---
up=(--set ragApiUrl=http://x --set serviceTokenSecret.name=s --set existingServiceAccount=k8s-c-abc
  --set uploads.bucket=b-1 --set uploads.queueUrl=https://sqs.us-west-2.amazonaws.com/5/q
  --set uploads.region=eu-central-1 --set uploads.role_arn=arn:aws:iam::9:role/up)
upx=$(helm template t "$chart" "${up[@]}")
grep -A1 'name: SOURCE_JSON$' <<<"$upx" | grep -qF '\"region\":\"eu-central-1\"' || fail "C-C2: uploads SOURCE_JSON region"
grep -A1 'name: SOURCE_JSON$' <<<"$upx" | grep -qF '\"role_arn\":\"arn:aws:iam::9:role/up\"' || fail "C-C2: uploads SOURCE_JSON role_arn"
grep -A1 'name: SOURCES_JSON$' <<<"$upx" | grep -qF '\"region\":\"eu-central-1\"' || fail "C-C2: events SOURCES_JSON uploads region"
grep -A1 'name: SOURCES_JSON$' <<<"$upx" | grep -qF '\"role_arn\":\"arn:aws:iam::9:role/up\"' || fail "C-C2: events SOURCES_JSON uploads role_arn"

# --- final review C-I5: region / role_arn keys are emitted only when non-empty (older consumer
# images build SourceSpec(**json) and crash on keys they do not know) ---
plain=$(helm template t "$chart" --set ragApiUrl=http://x --set serviceTokenSecret.name=s --set existingServiceAccount=k8s-c-abc \
  --set uploads.bucket=b-1 --set uploads.queueUrl=https://sqs.us-west-2.amazonaws.com/5/q \
  --set-json 'sources=[{"id":"kb","bucket":"b","import_now":true,"sync":"events_sweep","schedule":"0 * * * *"}]')
for v in SOURCE_JSON SOURCES_JSON; do
  lines=$(grep -A1 "name: $v\$" <<<"$plain" | grep 'value:')
  [ -n "$lines" ] || fail "C-I5: $v not rendered"
  grep -qF '\"region\"' <<<"$lines" && fail "C-I5: empty region must be omitted from $v: $lines"
  grep -qF '\"role_arn\"' <<<"$lines" && fail "C-I5: empty role_arn must be omitted from $v: $lines"
done
expect_env "C-I5: non-empty user region still emitted in SOURCES_JSON" \
  '[{"id":"kb","bucket":"b","import_now":false,"sync":"events","region":"eu-west-1"}]' \
  'SOURCES_JSON' '\"region\":\"eu-west-1\"' --set eventsQueueUrl=https://q

echo "rag-sync render OK"
