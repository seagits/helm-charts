# sg-db

One Postgres 17 or MySQL 8.4 database (official images) with nightly backups to S3. Deployed by
Seagit's Database Stack template; the platform fills the `${seagit.*}` values below.

## What it deploys

| Object | Notes |
|---|---|
| StatefulSet `<release>` | 1 replica, PVC on `storage.storageClass`, off spot nodes (`avoidSpot`), owner label `seagit.io/deployment` so platform Stop/Start can scale it |
| Service `<release>` | ClusterIP: `<release>.<namespace>.svc.cluster.local` |
| Service `<release>-vpc` | only with `reach: vpc` — an internal NLB, labelled `seagit.io/report-address: "true"` so the worker records its hostname |
| Secret `<release>-auth` | admin and app passwords |
| ServiceAccount | for the backup jobs, annotated with the IRSA role |
| CronJob `<release>-backup` | nightly backup |
| Job `<release>-backup-first` | `post-install` hook: first backup (also makes the platform deploy this chart through its Tier B path) |
| Job `<release>-backup-final` | `pre-delete` hook: final backup; a failure fails the uninstall. Absent when `backup.onDelete: false` |

## Values

| Key | Default | Notes |
|---|---|---|
| `engine` | `postgres` | `postgres` or `mysql` |
| `database.name` / `database.user` | `app` / `app` | the app user has full rights on this database only |
| `auth.adminPassword` / `auth.appPassword` | — | required; Seagit: `${seagit.secrets.DB_ADMIN_PASSWORD}` / `${seagit.secrets.DB_APP_PASSWORD}` |
| `storage.size` / `storage.storageClass` | `20Gi` / `ebs-csi-slow-del` | |
| `reach` | `cluster` | `cluster` or `vpc` |
| `avoidSpot` | `true` | `node.kubernetes.io/lifecycle NotIn [spot]` |
| `seagit.deploymentId` | — | Seagit: `${seagit.app.deployment_id}` |
| `serviceAccount.name` / `serviceAccount.roleArn` | — | Seagit: `${seagit.app.sa_name}` / `${seagit.app.role_arn}` |
| `backup.bucket` / `backup.region` | — | required bucket; Seagit: `${stack_bucket.name}` / `${stack_bucket.region}` (the bucket's region) |
| `backup.prefix` | `backups/` | folder the backups go in (ends with `/`); Seagit: `${stack_bucket.prefix}` — `backups/` in a new bucket, the chosen folder in an existing one |
| `backup.schedule` | `0 3 * * *` | |
| `backup.retentionDays` | `7` | the backup job prunes older dumps itself |
| `backup.activeDeadlineSeconds` / `backup.hookDeadlineSeconds` | `3600` / `540` | nightly / first+final; the hooks must finish inside the Seagit worker's 600s window |
| `backup.onDelete` | `true` | `false` = "Delete anyway": no final backup |
| `backup.firstBackup` | `true` | keep `true` in production (CI sets `false`) |
| `backup.endpointUrl` / `backup.extraEnvFromSecret` | `""` | tests only (an S3 stand-in and its credentials) |

## Backups

Objects in `s3://<bucket>/<prefix>`: `<YYYYMMDDTHHMMSSZ>.sql.gz` (first and nightly, pruned after
`retentionDays`), `final-<timestamp>.sql.gz` (never pruned) and `_status.json`
(`time, mode, ok, skipped, object, size, error`). While the database is down the nightly job writes
`skipped` and exits 0; the first and final backups fail instead.

## Tests

```bash
charts/sg-db/tests/render_test.sh   # helm template assertions, no cluster
charts/sg-db/tests/kind_test.sh     # kind + SeaweedFS (S3 stand-in), ~10 min, both engines
```
