# Monitoring Citus on Kubernetes

This guide explains how to monitor your Patroni-based Citus cluster running on Kubernetes using Prometheus and Grafana.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Deployment Scenarios](#deployment-scenarios)
- [Metrics Reference](#metrics-reference)
- [Grafana Dashboards](#grafana-dashboards)
- [Alerting Rules](#alerting-rules)
- [Troubleshooting](#troubleshooting)

## Overview

The monitoring solution provides comprehensive observability for:
- **Patroni cluster health**: Failover detection, leader election, cluster locks
- **PostgreSQL performance**: Connections, transactions, cache hits, locks
- **Citus distribution**: Worker nodes, shard placement, distributed queries
- **Replication lag**: Per-node replication status and lag metrics
- **Resource usage**: CPU, memory, disk I/O per pod

### Components

1. **Patroni REST API** (port 8008): Built-in metrics endpoint providing cluster health
2. **postgres_exporter** (port 9187): Sidecar container exporting PostgreSQL metrics
3. **Custom Queries**: Citus-specific metrics for distributed database monitoring
4. **Prometheus**: Metrics collection and storage
5. **Grafana**: Visualization and dashboarding

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │  Citus Coordinator Pod (citusdemo-0-0)             │    │
│  │  ┌──────────────┐  ┌─────────────────────────┐    │    │
│  │  │  PostgreSQL  │  │  postgres_exporter      │    │    │
│  │  │  + Patroni   │  │  :9187/metrics          │    │    │
│  │  │  :8008/metrics│  └─────────────────────────┘    │    │
│  │  └──────────────┘                                   │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │  Citus Worker Pod (citusdemo-1-0)                  │    │
│  │  ┌──────────────┐  ┌─────────────────────────┐    │    │
│  │  │  PostgreSQL  │  │  postgres_exporter      │    │    │
│  │  │  + Patroni   │  │  :9187/metrics          │    │    │
│  │  │  :8008/metrics│  └─────────────────────────┘    │    │
│  │  └──────────────┘                                   │    │
│  └────────────────────────────────────────────────────┘    │
│                         ▲                                    │
│                         │ scrape                            │
│  ┌──────────────────────┴────────────────────────────┐    │
│  │             Prometheus                             │    │
│  │  - ServiceMonitor / PodMonitor (Operator)         │    │
│  │  - Manual scrape config (Standalone)              │    │
│  └────────────────────────────────────────────────────┘    │
│                         ▲                                    │
│                         │ query                             │
│  ┌──────────────────────┴────────────────────────────┐    │
│  │             Grafana                                │    │
│  │  - Pre-built dashboards                           │    │
│  │  - Custom Citus metrics                           │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### How It Works

1. **Metric Collection**:
   - Patroni REST API exposes cluster health metrics at `:8008/metrics`
   - postgres_exporter connects to local PostgreSQL and exposes metrics at `:9187/metrics`
   - Custom queries ConfigMap provides Citus-specific metric definitions

2. **Scraping**:
   - **With Prometheus Operator**: ServiceMonitor/PodMonitor CRDs enable auto-discovery
   - **Standalone Prometheus**: Manual scrape configuration targeting services

3. **Visualization**:
   - Grafana queries Prometheus for metrics
   - Pre-built community dashboards (9628, 18870)
   - Custom dashboards for Citus-specific metrics

## Quick Start

### Enable Monitoring (Basic)

```bash
# Install with monitoring enabled
helm install citusdemo ./helm/citus-cluster \
  --set monitoring.enabled=true \
  --set monitoring.postgresExporter.enabled=true \
  --set monitoring.postgresExporter.customQueries.enabled=true
```

This enables:
- ✅ postgres_exporter sidecar on all pods
- ✅ Custom Citus queries
- ✅ Metrics ports exposed on services
- ✅ Prometheus annotations for scraping

### Enable Monitoring (Prometheus Operator)

```bash
# Install with Prometheus Operator support
helm install citusdemo ./helm/citus-cluster \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.serviceMonitor.additionalLabels.prometheus=kube-prometheus
```

This creates:
- ✅ ServiceMonitor CRDs for automatic discovery
- ✅ Proper label selectors for Prometheus

### Enable Monitoring (Full Stack)

```bash
# Install with full monitoring stack
helm install citusdemo ./helm/citus-cluster \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.grafanaDashboards.enabled=true \
  --set monitoring.serviceMonitor.additionalLabels.prometheus=kube-prometheus \
  --set monitoring.grafanaDashboards.labels.grafana_dashboard="1"
```

## Deployment Scenarios

### Scenario 1: With Existing Prometheus Operator

**Prerequisites**:
- Prometheus Operator installed
- Know your Prometheus selector labels

**Steps**:

1. Deploy cluster with ServiceMonitor:
```bash
helm install citusdemo ./helm/citus-cluster \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.serviceMonitor.additionalLabels.prometheus=kube-prometheus
```

2. Verify ServiceMonitor creation:
```bash
kubectl get servicemonitor -l cluster-name=citusdemo
```

3. Check Prometheus targets:
```bash
# Port-forward Prometheus
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090

# Open browser: http://localhost:9090/targets
# Look for citusdemo targets
```

### Scenario 2: With Standalone Prometheus

**Prerequisites**:
- Prometheus installed (not Operator)
- Access to Prometheus configuration

**Steps**:

1. Deploy cluster with monitoring enabled:
```bash
helm install citusdemo ./helm/citus-cluster \
  --set monitoring.enabled=true
```

2. Add scrape config to Prometheus:
```yaml
# prometheus.yml
scrape_configs:
  # Patroni metrics
  - job_name: 'citus-patroni'
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names:
            - default
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_cluster_name]
        action: keep
        regex: citusdemo
      - source_labels: [__meta_kubernetes_pod_container_port_number]
        action: keep
        regex: "8008"
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_citus_group]
        target_label: citus_group
      - source_labels: [__meta_kubernetes_pod_label_citus_type]
        target_label: citus_type
    metrics_path: /metrics

  # postgres_exporter metrics
  - job_name: 'citus-postgres-exporter'
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names:
            - default
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_cluster_name]
        action: keep
        regex: citusdemo
      - source_labels: [__meta_kubernetes_pod_container_port_number]
        action: keep
        regex: "9187"
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_citus_group]
        target_label: citus_group
      - source_labels: [__meta_kubernetes_pod_label_citus_type]
        target_label: citus_type
```

3. Reload Prometheus:
```bash
# Send SIGHUP to Prometheus process or use API
curl -X POST http://prometheus:9090/-/reload
```

### Scenario 3: Using PodMonitor Instead of ServiceMonitor

If you prefer pod-level monitoring:

```bash
helm install citusdemo ./helm/citus-cluster \
  --set monitoring.enabled=true \
  --set monitoring.podMonitor.enabled=true \
  --set monitoring.podMonitor.additionalLabels.prometheus=kube-prometheus
```

**PodMonitor vs ServiceMonitor**:
- **ServiceMonitor**: Scrapes through Kubernetes services (load-balanced)
- **PodMonitor**: Scrapes pods directly (individual pod metrics)

Use **PodMonitor** when you need per-pod granularity for StatefulSet monitoring.

## Metrics Reference

### Patroni Metrics

Exposed on port **8008**, path **/metrics**

| Metric | Type | Description |
|--------|------|-------------|
| `patroni_postgres_running` | Gauge | 1 if PostgreSQL is running, 0 otherwise |
| `patroni_postmaster_start_time` | Gauge | PostgreSQL start time (Unix timestamp) |
| `patroni_primary` | Gauge | 1 if this node is primary, 0 if replica |
| `patroni_replica` | Gauge | 1 if this node is replica, 0 if primary |
| `patroni_xlog_location` | Gauge | Current WAL LSN location |
| `patroni_timeline` | Gauge | Current timeline (increments on failover) |
| `patroni_cluster_unlocked` | Gauge | 1 if cluster lock is not held, 0 if locked |
| `patroni_pending_restart` | Gauge | 1 if PostgreSQL restart is pending |
| `patroni_is_paused` | Gauge | 1 if Patroni is paused, 0 otherwise |

### postgres_exporter Metrics

Exposed on port **9187**, path **/metrics**

#### Connection Metrics
- `pg_stat_database_numbackends` - Number of active connections per database
- `pg_settings_max_connections` - Maximum allowed connections
- `pg_stat_activity_count` - Connections by state (active, idle, etc.)

#### Transaction Metrics
- `pg_stat_database_xact_commit` - Transactions committed
- `pg_stat_database_xact_rollback` - Transactions rolled back
- `pg_stat_database_tup_inserted` - Rows inserted
- `pg_stat_database_tup_updated` - Rows updated
- `pg_stat_database_tup_deleted` - Rows deleted

#### Cache Metrics
- `pg_stat_database_blks_hit` - Buffer cache hits
- `pg_stat_database_blks_read` - Disk reads
- `pg_cache_hit_ratio` - Cache hit ratio percentage

#### Lock Metrics
- `pg_locks_count` - Number of locks by type
- `pg_stat_database_deadlocks` - Deadlock count per database

#### Replication Metrics
- `pg_replication_lag` - Replication lag in seconds
- `pg_stat_replication_replay_lag` - Replay lag in bytes

### Custom Citus Metrics

Provided via custom queries ConfigMap

#### Worker Node Status
```promql
citus_worker_nodes_is_active{cluster_name="citusdemo"}
citus_worker_nodes_is_primary{cluster_name="citusdemo"}
```

#### Distributed Tables
```promql
citus_distributed_tables_distributed_table_count
citus_distributed_tables_hash_distributed_count
citus_distributed_tables_reference_table_count
```

#### Shard Placement
```promql
citus_shard_placements_shard_count{groupid="1"}
citus_shard_placements_active_shards{groupid="1"}
citus_shard_placements_inactive_shards{groupid="1"}
```

#### Query Performance
```promql
citus_distributed_queries_total_distributed_queries
citus_distributed_queries_avg_execution_time_ms
citus_distributed_queries_max_execution_time_ms
```

#### Metadata Sync
```promql
citus_metadata_sync_node_count
citus_metadata_sync_nodes_metadata_synced
```

## Grafana Dashboards

### Pre-built Community Dashboards

#### 1. PostgreSQL Database (ID: 9628)

**Import URL**: https://grafana.com/grafana/dashboards/9628

**Features**:
- Database overview with key metrics
- Connection and transaction rates
- Cache performance
- Table and index statistics
- Query performance
- Disk usage

**Import Steps**:
1. Open Grafana → Dashboards → Import
2. Enter dashboard ID: **9628**
3. Select Prometheus data source
4. Click Import

#### 2. Patroni Cluster Health (ID: 18870)

**Import URL**: https://grafana.com/grafana/dashboards/18870

**Features**:
- Cluster topology visualization
- Primary/replica identification
- Failover history (timeline changes)
- Replication lag monitoring
- Cluster lock status
- Pause detection

**Import Steps**:
1. Open Grafana → Dashboards → Import
2. Enter dashboard ID: **18870**
3. Select Prometheus data source
4. Click Import

### Custom Citus Dashboard

Create a new dashboard with these panels:

#### Panel 1: Active Worker Nodes
```promql
sum(citus_worker_nodes_is_active{cluster_name="citusdemo"})
```

#### Panel 2: Distributed Table Count
```promql
citus_distributed_tables_distributed_table_count{cluster_name="citusdemo"}
```

#### Panel 3: Shard Distribution by Worker
```promql
citus_shard_placements_shard_count{cluster_name="citusdemo"}
```

#### Panel 4: Distributed Query Rate
```promql
rate(citus_distributed_queries_total_distributed_queries{cluster_name="citusdemo"}[5m])
```

#### Panel 5: Average Query Execution Time
```promql
citus_distributed_queries_avg_execution_time_ms{cluster_name="citusdemo"}
```

#### Panel 6: Replication Lag by Node
```promql
citus_replication_lag_lag_seconds{cluster_name="citusdemo"}
```

#### Panel 7: Metadata Sync Status
```promql
citus_metadata_sync_nodes_metadata_synced{cluster_name="citusdemo"} / 
citus_metadata_sync_node_count{cluster_name="citusdemo"}
```

## Alerting Rules

### Prometheus Alert Rules

Create a file `citus-alerts.yaml`:

```yaml
groups:
  - name: citus_cluster_alerts
    interval: 30s
    rules:
      # PostgreSQL Down
      - alert: PostgreSQLDown
        expr: patroni_postgres_running == 0
        for: 1m
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "PostgreSQL is down"
          description: "PostgreSQL on {{ $labels.pod }} in cluster {{ $labels.cluster_name }} is not running"

      # No Primary in Cluster
      - alert: NoPrimaryInCluster
        expr: sum(patroni_primary{cluster_name="citusdemo", citus_group="0"}) == 0
        for: 2m
        labels:
          severity: critical
          component: patroni
        annotations:
          summary: "No primary coordinator in Citus cluster"
          description: "Citus coordinator group has no primary node"

      # High Replication Lag
      - alert: HighReplicationLag
        expr: citus_replication_lag_lag_seconds > 10
        for: 5m
        labels:
          severity: warning
          component: replication
        annotations:
          summary: "High replication lag detected"
          description: "Replication lag on {{ $labels.pod }} is {{ $value }}s (threshold: 10s)"

      # Worker Node Inactive
      - alert: CitusWorkerInactive
        expr: citus_worker_nodes_is_active == 0
        for: 2m
        labels:
          severity: warning
          component: citus
        annotations:
          summary: "Citus worker node inactive"
          description: "Worker node {{ $labels.nodename }}:{{ $labels.nodeport }} (group {{ $labels.groupid }}) is inactive"

      # Metadata Not Synced
      - alert: CitusMetadataNotSynced
        expr: |
          citus_metadata_sync_nodes_metadata_synced 
          < 
          citus_metadata_sync_node_count
        for: 5m
        labels:
          severity: warning
          component: citus
        annotations:
          summary: "Citus metadata not synced on all nodes"
          description: "{{ $value }} out of {{ citus_metadata_sync_node_count }} nodes have unsynced metadata"

      # High Connection Usage
      - alert: HighConnectionUsage
        expr: |
          (pg_stat_database_numbackends / pg_settings_max_connections) > 0.8
        for: 10m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "High connection usage"
          description: "{{ $labels.pod }} is using {{ $value | humanizePercentage }} of max connections"

      # Low Cache Hit Ratio
      - alert: LowCacheHitRatio
        expr: |
          rate(pg_stat_database_blks_hit[5m]) / 
          (rate(pg_stat_database_blks_hit[5m]) + rate(pg_stat_database_blks_read[5m])) < 0.90
        for: 15m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Low cache hit ratio"
          description: "Cache hit ratio on {{ $labels.pod }} is {{ $value | humanizePercentage }} (threshold: 90%)"

      # Deadlocks Detected
      - alert: DeadlocksDetected
        expr: increase(pg_stat_database_deadlocks[5m]) > 0
        for: 1m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Deadlocks detected"
          description: "{{ $value }} deadlocks detected on {{ $labels.pod }} in the last 5 minutes"

      # Failover Detected
      - alert: FailoverDetected
        expr: increase(patroni_timeline[5m]) > 0
        for: 1m
        labels:
          severity: info
          component: patroni
        annotations:
          summary: "Patroni failover detected"
          description: "Timeline changed on {{ $labels.pod }}, indicating a failover occurred"

      # Inactive Shards
      - alert: InactiveShardsDetected
        expr: citus_shard_placements_inactive_shards > 0
        for: 5m
        labels:
          severity: warning
          component: citus
        annotations:
          summary: "Inactive shards detected"
          description: "Worker group {{ $labels.groupid }} has {{ $value }} inactive shards"
```

Apply to Prometheus:
```bash
kubectl apply -f citus-alerts.yaml
```

## Troubleshooting

### Metrics Not Appearing in Prometheus

**Problem**: Prometheus targets show as down or metrics not visible

**Solutions**:

1. **Check pod status**:
```bash
kubectl get pods -l cluster-name=citusdemo
kubectl describe pod citusdemo-0-0
```

2. **Verify metrics endpoints**:
```bash
# Test Patroni metrics
kubectl exec citusdemo-0-0 -- curl -s localhost:8008/metrics | head

# Test postgres_exporter metrics
kubectl exec citusdemo-0-0 -c postgres-exporter -- curl -s localhost:9187/metrics | head
```

3. **Check ServiceMonitor**:
```bash
kubectl get servicemonitor -l cluster-name=citusdemo -o yaml
```

4. **Verify Prometheus service discovery**:
```bash
# Check Prometheus logs
kubectl logs -n monitoring prometheus-prometheus-0 | grep citus
```

### postgres_exporter Connection Errors

**Problem**: postgres_exporter can't connect to PostgreSQL

**Symptoms**:
```
level=error msg="Error opening connection to database: pq: password authentication failed"
```

**Solutions**:

1. **Check secret**:
```bash
kubectl get secret citusdemo -o jsonpath='{.data.superuser-password}' | base64 -d
```

2. **Verify environment variable**:
```bash
kubectl exec citusdemo-0-0 -c postgres-exporter -- env | grep DATA_SOURCE_NAME
```

3. **Test connection manually**:
```bash
kubectl exec citusdemo-0-0 -- psql -U postgres -d citus -c "SELECT version();"
```

### Custom Queries Not Working

**Problem**: Citus-specific metrics not appearing

**Solutions**:

1. **Check ConfigMap**:
```bash
kubectl get configmap citusdemo-exporter-queries -o yaml
```

2. **Verify mount in pod**:
```bash
kubectl exec citusdemo-0-0 -c postgres-exporter -- cat /etc/postgres-exporter/queries.yaml
```

3. **Check exporter logs**:
```bash
kubectl logs citusdemo-0-0 -c postgres-exporter
```

4. **Test query manually**:
```bash
kubectl exec citusdemo-0-0 -- psql -U postgres -d citus -c "SELECT * FROM pg_dist_node;"
```

### High Resource Usage

**Problem**: postgres_exporter using too much CPU/memory

**Solutions**:

1. **Adjust resource limits** in values.yaml:
```yaml
monitoring:
  postgresExporter:
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi
```

2. **Disable unnecessary metrics**:
```yaml
monitoring:
  postgresExporter:
    customQueries:
      enabled: false  # Disable custom queries if not needed
```

3. **Increase scrape interval**:
```yaml
monitoring:
  serviceMonitor:
    interval: 30s  # Reduce scrape frequency
```

### Grafana Dashboard Not Loading

**Problem**: Dashboard shows "No data" or errors

**Solutions**:

1. **Verify Prometheus data source**:
   - Grafana → Configuration → Data Sources
   - Test connection to Prometheus

2. **Check metric availability**:
```bash
# Query Prometheus directly
curl -G 'http://prometheus:9090/api/v1/query' \
  --data-urlencode 'query=patroni_postgres_running{cluster_name="citusdemo"}'
```

3. **Adjust time range**: Some metrics are counters and need time range

4. **Check label selectors**: Ensure cluster_name matches your deployment

## Performance Tuning

### Optimize Scrape Configuration

**Reduce cardinality**:
```yaml
# In custom queries, limit result rows
query: |
  SELECT ... FROM ...
  ORDER BY ... DESC
  LIMIT 10  # Limit to top 10 results
```

**Adjust scrape intervals**:
- **High-frequency** (15s): Patroni health, replication lag
- **Medium-frequency** (30s): PostgreSQL transactions, connections
- **Low-frequency** (60s): Table sizes, disk usage

### Resource Allocation

**Production recommendations**:
```yaml
monitoring:
  postgresExporter:
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
```

**For large clusters** (10+ worker groups):
```yaml
monitoring:
  postgresExporter:
    resources:
      requests:
        cpu: 200m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

## Additional Resources

- **postgres_exporter Documentation**: https://github.com/prometheus-community/postgres_exporter
- **Patroni Metrics**: https://patroni.readthedocs.io/en/latest/rest_api.html
- **Prometheus Operator**: https://prometheus-operator.dev/
- **Grafana Dashboard 9628**: https://grafana.com/grafana/dashboards/9628
- **Grafana Dashboard 18870**: https://grafana.com/grafana/dashboards/18870
- **Citus Documentation**: https://docs.citusdata.com/

## Summary

You now have a complete monitoring solution for your Citus cluster:

✅ **Patroni metrics** for cluster health and failover detection  
✅ **PostgreSQL metrics** for database performance  
✅ **Citus metrics** for distributed query and shard monitoring  
✅ **Pre-built dashboards** for quick visualization  
✅ **Alerting rules** for proactive issue detection  

For questions or issues, refer to the [main CLAUDE.md](../CLAUDE.md) or open an issue on GitHub.
