#!/bin/bash
set -euo pipefail

# 1. Загружаем реквизиты из Kubernetes Secret
export AWS_ACCESS_KEY_ID=$(kubectl get secret restic-backup-secret -n databases -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(kubectl get secret restic-backup-secret -n databases -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
export RESTIC_PASSWORD=$(kubectl get secret restic-backup-secret -n databases -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d)

MINIO_IP=$(kubectl get svc minio -n databases -o jsonpath='{.spec.clusterIP}')
export RESTIC_REPOSITORY="s3:http://${MINIO_IP}:9000/homelab-backups-v2"

# 2. Автоматическая инициализация при первом запуске
if ! restic snapshots > /dev/null 2>&1; then
  echo "[INIT] Инициализация репозитория Restic..."
  restic init
fi

BACKUP_DIR=$(mktemp -d /tmp/homelab_backup_XXXXXX)
chmod 700 "$BACKUP_DIR"

cleanup() {
  rm -rf "$BACKUP_DIR"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD PG_PASS REDIS_PASS
}
trap cleanup EXIT

# 3. Дамп PostgreSQL Primary (без свечения пароля в ps aux)
echo "[1/4] Дамп PostgreSQL..."
PG_PASS=$(kubectl get secret postgres-postgresql -n databases -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl exec -i -n databases postgres-postgresql-primary-0 -- bash -c '
  umask 077
  printf "*:*:*:postgres:%s\n" "$1" > /tmp/.pgpass
  PGPASSFILE=/tmp/.pgpass pg_dumpall -U postgres
  rc=$?
  rm -f /tmp/.pgpass
  exit $rc
' -- "$PG_PASS" > "$BACKUP_DIR/postgres.sql"

# 4. Дамп Redis (передача пароля через stdin без свечения в CLI)
echo "[2/4] Дамп Redis..."
REDIS_PASS=$(kubectl get secret redis -n databases -o jsonpath='{.data.redis-password}' | base64 -d)
kubectl exec -i -n databases redis-master-0 -- bash -c '
  read -r PASS
  REDISCLI_AUTH="$PASS" redis-cli --no-auth-warning --rdb /tmp/dump.rdb > /dev/null
  cat /tmp/dump.rdb
  rm -f /tmp/dump.rdb
' <<< "$REDIS_PASS" > "$BACKUP_DIR/redis.rdb"

# 5. Снапшот Qdrant
echo "[3/4] Снапшот Qdrant..."
QDRANT_IP=$(kubectl get pod qdrant-0 -n default -o jsonpath='{.status.podIP}' 2>/dev/null || true)
if [ -n "$QDRANT_IP" ]; then
  SNAP_NAME=$(curl -s -X POST "http://${QDRANT_IP}:6333/snapshots" | jq -r '.result.name // empty')
  if [ -n "$SNAP_NAME" ]; then
    curl -s "http://${QDRANT_IP}:6333/snapshots/${SNAP_NAME}" -o "$BACKUP_DIR/qdrant_${SNAP_NAME}"
    curl -s -X DELETE "http://${QDRANT_IP}:6333/snapshots/${SNAP_NAME}" > /dev/null
  fi
fi

# 6. Загрузка в MinIO и проверка
echo "[4/4] Отправка в MinIO через Restic..."
restic backup "$BACKUP_DIR" --tag homelab-all
restic snapshots

echo "[5/5] Очистка устаревших снапшотов (ротация)..."
restic forget --keep-daily 7 --keep-weekly 4 --prune
