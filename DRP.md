# Disaster Recovery Plan (DRP)

## Сценарий 1: Отказ worker-ноды (например, node2)
1. Проверить статус кластера: `kubectl get nodes`
2. Убедиться, что кворум сохранен (2 из 3 нод в статусе Ready).
3. Kubernetes автоматически пересоздаст поды, которые были на node2, на оставшихся нодах.
4. Для возврата ноды: перезагрузить ВМ, выполнить `sudo systemctl start k3s`.

## Сценарий 2: Падение Primary базы данных
1. Проверить статус подов: `kubectl get pods -n databases`
2. Повысить реплику до мастера: 
   `kubectl exec -it postgres-postgresql-read-0 -n databases -- bash -c "pg_ctl promote -D /bitnami/postgresql/data"`
3. Перенастроить Service на новую Primary.
4. Восстановить данные из Restic, если требуется:
   `restic restore latest --target /tmp/restore`
   `psql -h <primary> -U postgres -f /tmp/restore/tmp/db.sql`

## Сценарий 3: Полная потеря кластера
1. Развернуть новые ВМ.
2. Запустить Ansible: `ansible-playbook -i inventory.ini site.yml`
3. Восстановить базы из MinIO через Restic.
4. Применить манифесты: `kubectl apply -f microservices.yaml -f ai-rag.yaml`
