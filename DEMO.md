# Check Traefik Ingress controller
kubectl get svc -n kube-system traefik
kubectl get ingress -A

#replica test
kubectl exec -n databases -it postgres-postgresql-primary-0 -- env PGPASSWORD=$(kubectl get secret -n databases postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d) psql -U postgres -c "CREATE TABLE repl_test (id int); INSERT INTO repl_test VALUES (42);"
#added 42 value
kubectl exec -n databases -it postgres-postgresql-read-0 -- env PGPASSWORD=$(kubectl get secret -n databases postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d) psql -U postgres -c "SELECT * FROM repl_test;"
#delete 42
kubectl exec -n databases -it postgres-postgresql-primary-0 -- env PGPASSWORD=$(kubectl get secret -n databases postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d) psql -U postgres -c "DROP TABLE repl_test;"
#password secret decode
kubectl get secret postgres-postgresql -n databases -o jsonpath="{.data.postgres-password}" | base64 --decode

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

# Check PodAntiAffinity rules
kubectl describe deployment auth-service | grep -A 8 "Pod Anti-Affinity"

# Test API Gateway via Ingress
curl -i -H "Host: api.homelab.local" http://192.168.100

# Check loaded Ollama models and test inference
OLLAMA_IP=$(kubectl get svc ollama -n default -o jsonpath='{.spec.clusterIP}')
curl -s "http://${OLLAMA_IP}:11434/api/tags" | jq

# Check Qdrant health and collections
QDRANT_IP=$(kubectl get pod qdrant-0 -n default -o jsonpath='{.status.podIP}')
curl -s "http://${QDRANT_IP}:6333/healthz" ; echo
curl -s "http://${QDRANT_IP}:6333/collections" | jq

# Check secrets and script permissions (700)
kubectl get secret restic-backup-secret -n databases
ls -la ~/k3s-ai-db/*.sh

#password in contaner
kubectl exec -it postgres-postgresql-primary-0 -n databases -- cat /opt/bitnami/postgresql/secrets/postgres-password

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
kubectl run -it --rm test-ollama --image=curlimages/curl --restart=Never -- curl -s -X POST http://ollama:11434/api/generate -d '{"model":"qwen2.5:1.5b","prompt":"Say hello","stream":false}'

# Check monitoring stack pods and Ingress
kubectl get pods -n monitoring -o wide
kubectl get ingress -n monitoring
#  Ingress
kubectl get ingress -A```
