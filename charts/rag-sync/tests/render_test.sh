#!/usr/bin/env bash
# Render assertions for rag-sync (no cluster needed). Run from the repo root.
set -euo pipefail
chart=charts/rag-sync
out=$(helm template t "$chart" \
  --set ragApiUrl=http://api.apps.svc.cluster.local:8000 \
  --set serviceTokenSecret.name=rag-secrets \
  --set-json 'sources=[{"id":"docs","bucket":"b1","prefix":"kb/","mode":"both","schedule":"*/30 * * * *","roleArn":"arn:aws:iam::1:role/r-docs","mirrorDeletes":true},{"id":"faq","bucket":"b2","mode":"once"}]')
fail() { echo "FAIL: $1"; exit 1; }
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
helm lint "$chart" >/dev/null || fail "helm lint"
echo "rag-sync render OK"
