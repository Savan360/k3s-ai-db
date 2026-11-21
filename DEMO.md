# K3s AI & Microservices Cluster — Demo Runbook

## 1. K3s Cluster & Traefik
```bash
# Check nodes status and resources
kubectl get nodes -o wide
kubectl top nodes

# Check Traefik Ingress controller
kubectl get svc -n kube-system traefik
kubectl get ingress -A
```

## 2. Databases (PostgreSQL, Redis, MinIO)
```bash
# Check pods placement across nodes
kubectl get pods -n databases -o wide

# Verify PostgreSQL Primary-Replica streaming
PG_PASS=$(kubectl get secret postgres-postgresql -n databases -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl exec -n databases postgres-postgresql-primary-0 -- env PGPASSWORD="$PG_PASS" psql -U postgres -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"
kubectl exec -n databases postgres-postgresql-read-0 -- env PGPASSWORD="$PG_PASS" psql -U postgres -c "SELECT pg_is_in_recovery();"

# Verify Redis connectivity
REDIS_PASS=$(kubectl get secret redis -n databases -o jsonpath='{.data.redis-password}' | base64 -d)
kubectl exec -n databases redis-master-0 -- env REDISCLI_AUTH="$REDIS_PASS" redis-cli --no-auth-warning ping

# Verify MinIO S3 health
MINIO_IP=$(kubectl get svc minio -n databases -o jsonpath='{.spec.clusterIP}')
curl -I "http://${MINIO_IP}:9000/minio/health/live"
```

## 3. Microservices & PodAntiAffinity
```bash
# Check pods isolation across worker nodes
kubectl get pods -n default -o wide

# Check PodAntiAffinity rules
kubectl describe deployment auth-service | grep -A 8 "Pod Anti-Affinity"

# Test API Gateway via Ingress
curl -i -H "Host: api.homelab.local" http://192.168.100
```

## 4. AI / LLM (Ollama) & Vector DB (Qdrant)
```bash
# Check loaded Ollama models and test inference
OLLAMA_IP=$(kubectl get svc ollama -n default -o jsonpath='{.spec.clusterIP}')
curl -s "http://${OLLAMA_IP}:11434/api/tags" | jq

MODEL_NAME=(curl -s "http://{OLLAMA_IP}:11434/api/tags" | jq -r '.models[0].name')
curl -s "http://\({OLLAMA_IP}:11434/api/generate" -d "{\"model\": \"\){MODEL_NAME}\", \"prompt\": \"Say hello in 3 words\", \"stream\": false}" | jq -r '.response'

# Check Qdrant health and collections
QDRANT_IP=$(kubectl get pod qdrant-0 -n default -o jsonpath='{.status.podIP}')
curl -s "http://${QDRANT_IP}:6333/healthz" ; echo
curl -s "http://${QDRANT_IP}:6333/collections" | jq
```

## 5. Backup & Restore (Restic -> MinIO)
```bash
# Check secrets and script permissions (700)
kubectl get secret restic-backup-secret -n databases
ls -la ~/k3s-ai-db/*.sh

# Run full encrypted backup
~/k3s-ai-db/backup_all.sh

# Run full restore (PostgreSQL, Redis, Qdrant)
~/k3s-ai-db/restore_all.sh

# Verify restored PostgreSQL database
PG_PASS=$(kubectl get secret postgres-postgresql -n databases -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl exec -n databases postgres-postgresql-primary-0 -- env PGPASSWORD="$PG_PASS" psql -U postgres -c "\l" | grep test_restore
kubectl exec -n databases postgres-postgresql-primary-0 -- env PGPASSWORD="$PG_PASS" psql -U postgres -d test_restore -c "\dt"

# Verify restored Redis keys
REDIS_PASS=$(kubectl get secret redis -n databases -o jsonpath='{.data.redis-password}' | base64 -d)
kubectl exec -n databases redis-master-0 -- env REDISCLI_AUTH="$REDIS_PASS" redis-cli --no-auth-warning KEYS '*'

# Verify restored Qdrant collections
QDRANT_IP=$(kubectl get pod qdrant-0 -n default -o jsonpath='{.status.podIP}')
curl -s "http://${QDRANT_IP}:6333/collections" | jq '.result.collections'
```

## 6. Ansible & Docs
```bash
# Check repository structure and permissions
ls -la ~/k3s-ai-db/ ~/k3s-ai-db/ansible/
head -n 25 ~/k3s-ai-db/README.md ~/k3s-ai-db/DRP.md
```

## 7. Observability (Prometheus, Grafana, Loki)
```bash
# Check monitoring stack pods and Ingress
kubectl get pods -n monitoring -o wide
kubectl get ingress -n monitoring
#  Ingress
kubectl get ingress -A```

* **Grafana:** `http://homelab.local` (Metrics: *Dashboards -> Compute Resources / Node*, Logs: *Explore -> Loki -> `{namespace="default"}`*)
