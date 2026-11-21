#!/bin/bash
set -euo pipefail

SNAPSHOT_ID="${1:-latest}"
TARGET_PG_DB="${2:-test_restore}"

# 1. Загружаем реквизиты из Kubernetes Secret
export AWS_ACCESS_KEY_ID=$(kubectl get secret restic-backup-secret -n databases -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(kubectl get secret restic-backup-secret -n databases -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
export RESTIC_PASSWORD=$(kubectl get secret restic-backup-secret -n databases -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d)

MINIO_IP=$(kubectl get svc minio -n databases -o jsonpath='{.spec.clusterIP}')
export RESTIC_REPOSITORY="s3:http://${MINIO_IP}:9000/homelab-backups-v2"

RESTORE_DIR=$(mktemp -d /tmp/homelab_restore_XXXXXX)
chmod 700 "$RESTORE_DIR"

cleanup() {
  rm -rf "$RESTORE_DIR"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD PG_PASS REDIS_PASS
}
trap cleanup EXIT

# 2. Скачивание и расшифровка снапшота из MinIO
echo "=== [1/4] Скачивание снапшота ($SNAPSHOT_ID) из MinIO ==="
restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR"

# ==========================================
# 3. Восстановление PostgreSQL
# ==========================================
echo "=== [2/4] Восстановление PostgreSQL в тестовую БД '$TARGET_PG_DB' ==="
SQL_DUMP=$(find "$RESTORE_DIR" -name "postgres.sql" | head -n 1)
if [ -n "$SQL_DUMP" ]; then
  PG_PASS=$(kubectl get secret postgres-postgresql -n databases -o jsonpath='{.data.postgres-password}' | base64 -d)

  run_psql() {
    kubectl exec -i -n databases postgres-postgresql-primary-0 -- bash -c '
      umask 077
      printf "*:*:*:postgres:%s\n" "$1" > /tmp/.pgpass
      shift
      PGPASSFILE=/tmp/.pgpass psql -U postgres "$@"
      rc=$?
      rm -f /tmp/.pgpass
      exit $rc
    ' -- "$PG_PASS" "$@"
  }

  run_psql -c "DROP DATABASE IF EXISTS ${TARGET_PG_DB};"
  run_psql -c "CREATE DATABASE ${TARGET_PG_DB};"

  grep -vE '^(\\connect|CREATE DATABASE|ALTER DATABASE|DROP DATABASE|CREATE ROLE|ALTER ROLE)' "$SQL_DUMP" | \
    run_psql -d "$TARGET_PG_DB" > /dev/null

  echo "PostgreSQL: база '$TARGET_PG_DB' успешно восстановлена. Список таблиц:"
  run_psql -d "$TARGET_PG_DB" -c "\dt"
else
  echo "Внимание: postgres.sql не найден в снапшоте, пропускаем."
fi

# ==========================================
# 4. Восстановление Redis
# ==========================================
echo "=== [3/4] Восстановление Redis ==="
RDB_DUMP=$(find "$RESTORE_DIR" -name "redis.rdb" | head -n 1)
if [ -n "$RDB_DUMP" ]; then
  # Определяем путь к директории данных Redis внутри пода (обычно /bitnami/redis/data или /data)
  REDIS_DATA_DIR=$(kubectl exec -n databases redis-master-0 -- redis-cli --no-auth-warning -a "$(kubectl get secret redis -n databases -o jsonpath='{.data.redis-password}' | base64 -d)" CONFIG GET dir 2>/dev/null | tail -n 1 || echo "/bitnami/redis/data")
  
  kubectl cp "$RDB_DUMP" "databases/redis-master-0:${REDIS_DATA_DIR}/dump.rdb"
  kubectl delete pod redis-master-0 -n databases --wait=true
  kubectl wait --for=condition=Ready pod/redis-master-0 -n databases --timeout=60s

  REDIS_PASS=$(kubectl get secret redis -n databases -o jsonpath='{.data.redis-password}' | base64 -d)
  KEYS_COUNT=$(kubectl exec -i -n databases redis-master-0 -- bash -c 'read -r P; REDISCLI_AUTH="$P" redis-cli --no-auth-warning DBSIZE' <<< "$REDIS_PASS")
  echo "Redis: восстановлен успешно ($KEYS_COUNT)."
else
  echo "Внимание: redis.rdb не найден в снапшоте, пропускаем."
fi

# ==========================================
# 5. Восстановление Qdrant
# ==========================================
echo "=== [4/4] Восстановление Qdrant ==="
QDRANT_SNAP=$(find "$RESTORE_DIR" -name "qdrant_*.snapshot" | head -n 1)
# Ищем под Qdrant в default или ai/databases неймспейсе
QDRANT_NS=$(kubectl get pods -A -l app=qdrant -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || kubectl get pods -A | awk '/qdrant/ {print $1; exit}')
QDRANT_POD=$(kubectl get pods -A | awk '/qdrant/ {print $2; exit}')

if [ -n "$QDRANT_SNAP" ] && [ -n "$QDRANT_POD" ]; then
  QDRANT_IP=$(kubectl get pod "$QDRANT_POD" -n "$QDRANT_NS" -o jsonpath='{.status.podIP}')
  curl -s -X POST "http://${QDRANT_IP}:6333/snapshots/recover" \
    -H "Content-Type: multipart/form-data" \
    -F "snapshot=@${QDRANT_SNAP}" > /dev/null
  echo "Qdrant: снапшот загружен. Активные коллекции:"
  curl -s "http://${QDRANT_IP}:6333/collections" | jq -c '.result.collections'
else
  echo "Внимание: снапшот Qdrant не найден в бэкапе или под Qdrant не запущен, пропускаем."
fi

echo "=== ПОЛНОЕ ВОССТАНОВЛЕНИЕ ИЗ СНАПШОТА '$SNAPSHOT_ID' ЗАВЕРШЕНО ==="
