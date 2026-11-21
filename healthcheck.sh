#!/bin/bash
set -u

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

check() {
  local name="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    printf "[ ${GREEN}OK${NC} ] %s\n" "$name"
  else
    printf "[${RED}FAIL${NC}] %s\n" "$name"
  fi
}

echo "=== K3S CLUSTER QUICK HEALTHCHECK ==="

# 1. Nodes & Traefik
check "All 3 K3s nodes Ready" bash -c '[ "$(kubectl get nodes --no-headers | grep -c " Ready")" -eq 3 ]'
check "Traefik Ingress (api.homelab.local)" bash -c 'curl -s -o /dev/null -w "%{http_code}" -H "Host: api.homelab.local" http://127.0.0/ | grep -qE "^(200|302|307)$"'
check "Grafana Ingress (grafana.homelab.local)" bash -c 'curl -s -o /dev/null -w "%{http_code}" -H "Host: grafana.homelab.local" http://127.0.0/ | grep -qE "^(200|302|307)$"'
check "MinIO UI Ingress (minio.homelab.local)" bash -c 'curl -s -o /dev/null -w "%{http_code}" -H "Host: minio.homelab.local" http://127.0.0/ | grep -qE "^(200|302|307)$"'
check "Qdrant UI Ingress (qdrant.homelab.local)" bash -c 'curl -s -o /dev/null -w "%{http_code}" -H "Host: qdrant.homelab.local" http://127.0.0/dashboard | grep -qE "^(200|302|307)$"'

# 2. Microservices PodAntiAffinity (3 unique nodes)
check "Microservices isolated on 3 nodes" bash -c '[ "$(kubectl get pods -n default -l "app in (api-gateway,auth-service,worker-service)" -o jsonpath="{.items[*].spec.nodeName}" | tr " " "\n" | sort -u | wc -l)" -eq 3 ]'

# 3. Databases & Replication
PG_PASS=$(kubectl get secret postgres-postgresql -n databases -o jsonpath='{.data.postgres-password}' | base64 -d)
check "PostgreSQL Primary (node2)" kubectl exec -n databases postgres-postgresql-primary-0 -- env PGPASSWORD="$PG_PASS" pg_isready -U postgres
check "PostgreSQL Streaming Replication" bash -c 'kubectl exec -n databases postgres-postgresql-primary-0 -- env PGPASSWORD="'"$PG_PASS"'" psql -U postgres -tAc "SELECT state FROM pg_stat_replication;" | grep -q "streaming"'
check "PostgreSQL Read Replica (node3)" bash -c 'kubectl exec -n databases postgres-postgresql-read-0 -- env PGPASSWORD="'"$PG_PASS"'" psql -U postgres -tAc "SELECT pg_is_in_recovery();" | grep -q "t"'

REDIS_PASS=$(kubectl get secret redis -n databases -o jsonpath='{.data.redis-password}' | base64 -d)
check "Redis Master (PING -> PONG)" bash -c 'kubectl exec -n databases redis-master-0 -- env REDISCLI_AUTH="'"$REDIS_PASS"'" redis-cli ping | grep -q "PONG"'

MINIO_IP=$(kubectl get svc minio -n databases -o jsonpath='{.spec.clusterIP}')
check "MinIO S3 API" curl -sf "http://${MINIO_IP}:9000/minio/health/live"

# 4. AI / RAG Stack
OLLAMA_IP=$(kubectl get svc ollama -n default -o jsonpath='{.spec.clusterIP}')
check "Ollama LLM API" curl -sf "http://${OLLAMA_IP}:11434/api/tags"

QDRANT_IP=$(kubectl get pod qdrant-0 -n default -o jsonpath='{.status.podIP}')
check "Qdrant Vector DB API" curl -sf "http://${QDRANT_IP}:6333/healthz"

# 5. Backups (Restic)
AWS_ACCESS_KEY_ID=$(kubectl get secret restic-backup-secret -n databases -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
AWS_SECRET_ACCESS_KEY=$(kubectl get secret restic-backup-secret -n databases -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
RESTIC_PASSWORD=$(kubectl get secret restic-backup-secret -n databases -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD
export RESTIC_REPOSITORY="s3:http://${MINIO_IP}:9000/homelab-backups-v2"
check "Restic S3 Backup Repository" restic snapshots

echo "====================================="
