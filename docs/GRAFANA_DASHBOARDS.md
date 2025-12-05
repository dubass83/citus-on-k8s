# Grafana Dashboard Import Instructions

This Citus cluster cituspreprod exposes metrics for monitoring via:
- Patroni REST API (port 8008, path /metrics)
- postgres_exporter (port 9187, path /metrics)
## Pre-built Grafana Dashboards
Import these community dashboards from https://grafana.com/grafana/dashboards/
### 1. PostgreSQL Database Monitoring (Dashboard ID: 9628)
- **URL**: https://grafana.com/grafana/dashboards/9628
- **Description**: Comprehensive PostgreSQL metrics from postgres_exporter
- **Metrics Source**: postgres_exporter
- **Key Metrics**:
  - Connection counts and states
  - Transaction rates (commits, rollbacks)
  - Cache hit ratios
  - Database sizes
  - Locks and deadlocks
  - Query performance
  - Table and index statistics
### 2. Patroni Cluster Monitoring (Dashboard ID: 18870)
- **URL**: https://grafana.com/grafana/dashboards/18870
- **Description**: Patroni cluster health and failover monitoring
- **Metrics Source**: Patroni REST API
- **Key Metrics**:
  - Cluster lock status
  - Primary/Replica identification
  - PostgreSQL process status
  - Replication lag
  - Timeline changes (failover detection)
  - Cluster pause status
## Custom Citus Metrics
The following custom metrics are available via postgres_exporter custom queries:
### Worker Node Metrics
- `citus_worker_nodes_is_active` - Worker node active status
- `citus_worker_nodes_is_primary` - Worker primary node indicator
### Distributed Table Metrics
- `citus_distributed_tables_distributed_table_count` - Total distributed tables
- `citus_distributed_tables_hash_distributed_count` - Hash-distributed tables
- `citus_distributed_tables_reference_table_count` - Reference tables
### Shard Placement Metrics
- `citus_shard_placements_shard_count` - Shards per worker group
- `citus_shard_placements_active_shards` - Active shards
- `citus_shard_placements_inactive_shards` - Inactive shards
### Connection Metrics
- `citus_worker_connections_connection_count` - Connections by backend type
### Query Performance Metrics
- `citus_distributed_queries_total_distributed_queries` - Total distributed queries
- `citus_distributed_queries_avg_execution_time_ms` - Average query time
- `citus_distributed_queries_max_execution_time_ms` - Maximum query time
### Replication Metrics
- `citus_replication_lag_lag_seconds` - Replication lag in seconds
- `citus_replication_lag_lag_bytes` - Replication lag in bytes
### Metadata Sync Metrics
- `citus_metadata_sync_node_count` - Total worker nodes
- `citus_metadata_sync_nodes_with_metadata` - Nodes with metadata
- `citus_metadata_sync_nodes_metadata_synced` - Nodes with synced metadata
## PromQL Query Examples
### Check if all nodes are running
```promql
patroni_postgres_running{cluster_name="cituspreprod"}
```
### Identify the primary coordinator
```promql
patroni_primary{cluster_name="cituspreprod", citus_group="0"}
```
### Monitor replication lag across all workers
```promql
citus_replication_lag_lag_seconds{cluster_name="cituspreprod"}
```
### Count active worker nodes
```promql
sum(citus_worker_nodes_is_active{cluster_name="cituspreprod"})
```
### Monitor distributed query performance
```promql
rate(citus_distributed_queries_total_distributed_queries{cluster_name="cituspreprod"}[5m])
```
## Alerting Rules Examples
### PostgreSQL Down Alert
```yaml
- alert: PostgreSQLDown
  expr: patroni_postgres_running{cluster_name="cituspreprod"} == 0
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "PostgreSQL is down on {{ $labels.pod }}"
```
### High Replication Lag Alert
```yaml
- alert: HighReplicationLag
  expr: citus_replication_lag_lag_seconds{cluster_name="cituspreprod"} > 10
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High replication lag on {{ $labels.pod }}: {{ $value }}s"
```
### Worker Node Inactive Alert
```yaml
- alert: CitusWorkerInactive
  expr: citus_worker_nodes_is_active{cluster_name="cituspreprod"} == 0
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Citus worker {{ $labels.nodename }} is inactive"
```
### Metadata Not Synced Alert
```yaml
- alert: CitusMetadataNotSynced
  expr: |
    citus_metadata_sync_nodes_metadata_synced{cluster_name="cituspreprod"}
    <
    citus_metadata_sync_node_count{cluster_name="cituspreprod"}
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Some Citus workers have unsynced metadata"
```
