# Backup & Restore (Nextcloud, Paperless)

## What is backed up

| What | How | Where |
|------|-----|-------|
| Paperless DB (MariaDB) | CronJob `paperless/db-dump`, 02:00: `mariadb-dump` → `db-dumps` PVC, 14 days | `apps/controllers/paperless-backup.yaml` |
| Nextcloud DB (**SQLite**, `data/nextcloud.db`) + `config/` | CronJob `nextcloud/nextcloud-backup`, 02:00: SQLite online backup + tar → `db-dumps` PVC, 14 days | `apps/controllers/nextcloud-backup.yaml` |
| Volumes in group `backup` | Longhorn RecurringJob `daily-backup`, 02:00 UTC, keeps 14 | `infrastructure/configs/longhorn-backup.yaml` |

Longhorn backup target: `nfs://192.168.178.239:/backup` (QNAP, no root squash).

Volumes in the `backup` group:
- `nextcloud/db-dumps`, `paperless/db-dumps` (label on the PVC in git)
- `paperless/paperless-paperless-ngx-media` (documents), `paperless/paperless-paperless-ngx-data`,
  `paperless/data-paperless-mariadb-0` (Helm-managed PVCs, labelled by hand, see below)

**Not** backed up: the Nextcloud files (`nextcloud/nextcloud-nextcloud`, 600Gi).
Nextcloud's MariaDB is unused (config.php: `dbtype => sqlite3`).

Add a volume to the backup group:

```bash
kubectl -n <ns> label pvc <pvc> recurring-job.longhorn.io/source=enabled recurring-job-group.longhorn.io/backup=enabled
# Longhorn copies the PVC labels to the volume; to be sure also label the volume directly:
kubectl -n longhorn label volumes.longhorn.io $(kubectl -n <ns> get pvc <pvc> -o jsonpath='{.spec.volumeName}') recurring-job-group.longhorn.io/backup=enabled
```

## Run a backup now

```bash
kubectl -n paperless create job --from=cronjob/db-dump dump-$(date +%s)
kubectl -n nextcloud create job --from=cronjob/nextcloud-backup backup-$(date +%s)
# after the dump jobs finished:
kubectl -n longhorn create job --from=cronjob/daily-backup backup-$(date +%s)
kubectl -n longhorn get backups.longhorn.io -o custom-columns=NAME:.metadata.name,VOL:.status.volumeName,STATE:.status.state,CREATED:.status.backupCreatedAt
```

## Restore a volume from a Longhorn backup

Works for every volume in the backup group (documents, DB volume, dumps).

1. Find the backup URL:
   ```bash
   kubectl -n longhorn get backups.longhorn.io -o custom-columns=VOL:.status.volumeName,CREATED:.status.backupCreatedAt,URL:.status.url | grep <volume>
   ```
2. Stop the app and remove the old PVC (only when replacing it):
   ```bash
   kubectl -n paperless scale deploy/paperless-paperless-ngx --replicas=0
   kubectl -n paperless delete pvc paperless-paperless-ngx-media
   ```
   Flux/Helm would recreate an empty PVC: suspend first with `flux suspend hr -n paperless paperless`.
3. Create the restored volume, a PV and the PVC with the old name:
   ```yaml
   apiVersion: longhorn.io/v1beta2
   kind: Volume
   metadata: {name: restored-media, namespace: longhorn}
   spec:
     fromBackup: "<URL from step 1>"
     size: "8589934592"          # status.volumeSize of the backup
     numberOfReplicas: 2
     frontend: blockdev
     dataEngine: v1
     accessMode: rwo
   ---
   apiVersion: v1
   kind: PersistentVolume
   metadata: {name: restored-media}
   spec:
     capacity: {storage: 8Gi}
     accessModes: [ReadWriteOnce]
     persistentVolumeReclaimPolicy: Retain
     storageClassName: longhorn-static
     csi: {driver: driver.longhorn.io, fsType: ext4, volumeHandle: restored-media}
   ---
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata: {name: paperless-paperless-ngx-media, namespace: paperless}
   spec:
     accessModes: [ReadWriteOnce]
     storageClassName: longhorn-static
     volumeName: restored-media
     resources: {requests: {storage: 8Gi}}
   ```
   Wait until `kubectl -n longhorn get volumes.longhorn.io restored-media -o jsonpath='{.status.restoreRequired}'` is `false`.
4. `flux resume hr -n paperless paperless`, scale the app back up.

The Longhorn UI (Backup → volume → Restore, then "Create PV/PVC") does the same.

## Restore the Paperless DB from a dump

```bash
kubectl -n paperless scale deploy/paperless-paperless-ngx --replicas=0
# dumps live in the paperless/db-dumps PVC; if the PVC is gone, restore it first (above)
kubectl -n paperless run dump-reader --rm -i --restart=Never --image=busybox:1.38 \
  --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"db-dumps"}}],"containers":[{"name":"r","image":"busybox:1.38","command":["cat","/d/<dump>.sql.gz"],"volumeMounts":[{"name":"d","mountPath":"/d"}]}]}}' \
  > paperless.sql.gz
gunzip -c paperless.sql.gz | kubectl -n paperless exec -i paperless-mariadb-0 -c mariadb -- \
  bash -c 'MYSQL_PWD=$MARIADB_ROOT_PASSWORD mariadb -uroot'
kubectl -n paperless scale deploy/paperless-paperless-ngx --replicas=1
```

The dump contains `CREATE DATABASE paperless` and drops/recreates every table.

## Restore Nextcloud (DB + config)

The `nextcloud/db-dumps` PVC holds `nextcloud-db-<ts>.sqlite.gz` and `nextcloud-config-<ts>.tar.gz`.

```bash
kubectl -n nextcloud scale deploy/nextcloud --replicas=0
# copy both files out of db-dumps (as above), then into the Nextcloud volume, e.g. with a helper pod
# that mounts nextcloud-nextcloud and db-dumps:
#   gunzip -c nextcloud-db-<ts>.sqlite.gz > <volume>/data/nextcloud.db   (remove nextcloud.db-wal/-shm)
#   tar -xzf nextcloud-config-<ts>.tar.gz -C <volume>                    (restores config/)
#   chown -R 33:33 <volume>/data/nextcloud.db <volume>/config
kubectl -n nextcloud scale deploy/nextcloud --replicas=1
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- su -s /bin/sh www-data -c "php occ status"
```

On a new installation the config is required: `instanceid`, `passwordsalt` and `secret` from `config.php`
must match, otherwise encrypted data and sessions are invalid.

## Major upgrades (MariaDB, Postgres)

1. Run the dump job and a Longhorn backup (see "Run a backup now"); check the dump exists.
2. Merge the Renovate PR (one major/minor at a time, e.g. MariaDB 11.4 → 11.8 → 12).
3. Check the DB pod log; run `mariadb-upgrade` in the pod if the image did not do it:
   `kubectl -n paperless exec paperless-mariadb-0 -c mariadb -- bash -c 'MYSQL_PWD=$MARIADB_ROOT_PASSWORD mariadb-upgrade -uroot'`
4. Check the app (log in, open a document).
5. If it fails: set the old image tag again, or empty the data PVC and restore the dump (above).

## Total loss

1. Rebuild the cluster from git (`talos/`, Flux bootstraps everything).
2. Longhorn reconnects to `nfs://192.168.178.239:/backup` (in git) and lists all backups.
3. Restore the volumes as above, suspend the HelmReleases while doing it.
4. Nextcloud: restore `config/` and `data/nextcloud.db`; the files (600Gi) are not in the backup.

## Restore test (2026-10-24)

Restored `paperless/db-dumps` and `paperless/…-media` from the NAS into a scratch namespace:
dump loaded into a throwaway MariaDB 11.4.4 → 289 documents / 67 tables, same as live;
all 868 media files byte-identical (sha256) to live.
