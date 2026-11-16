# Отказоустойчивый AI & Microservices кластер K3s

## Архитектурная схема (HLD)

```mermaid
flowchart TB
    subgraph Host["Windows Host (192.168.100.1)"]
        Browser[Browser / curl]
    end

    subgraph K3s_Cluster["K3s HA Cluster"]
        direction TB
        
        subgraph Node1["node1 (192.168.100.10)"]
            Traefik[Traefik Ingress]
            Auth[Auth Service]
            Ollama[Ollama LLM]
            Prom[Prometheus]
        end

        subgraph Node2["node2 (192.168.100.11)"]
            API[API Gateway]
            PG_Primary[(PostgreSQL Primary)]
            MinIO[MinIO S3]
        end

        subgraph Node3["node3 (192.168.100.12)"]
            Worker[Worker Service]
            PG_Replica[(PostgreSQL Replica)]
            Qdrant[(Qdrant Vector DB)]
            Redis[(Redis Cache)]
        end
    end

    Browser -->|api.homelab.local| Traefik
    Traefik --> API
    API --> Auth
    API --> Worker
    Worker --> PG_Primary
    Worker --> Ollama
    Worker --> Qdrant
    PG_Primary -.->|Replication| PG_Replica
    API --> Redis
    
    CronJob[Restic CronJob] -->|Encrypted Backup| MinIO
    CronJob --> PG_Primary
    
    Prom --> Node1 & Node2 & Node3
