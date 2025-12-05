# Postgres Exporter Replica Compatibility Fix

## Problem

The postgres_exporter was failing on replica/standby nodes with errors:

### Error 1: WAL Functions on Replicas
```
ts=2025-12-03T14:16:00.401Z caller=namespace.go:236 level=info err="Error running query on database \"127.0.0.1:5432\": pg_replication_slots pq: recovery is in progress"
ERROR: recovery is in progress
HINT: WAL control functions cannot be executed during recovery.
```

**Root Cause**: The default postgres_exporter queries for `pg_replication_slots` use `pg_current_wal_lsn()` - a function that **cannot run on standby nodes** during recovery.

### Error 2: Missing Citus Tables on System Databases
```
ts=2025-12-03T14:32:01.137Z caller=namespace.go:236 level=info err="Error running query on database \"127.0.0.1:5432\": citus_shard_placements pq: relation \"pg_dist_placement\" does not exist"
ERROR: relation "pg_dist_node" does not exist
ERROR: relation "pg_stat_statements" does not exist
```

**Root Cause**: When `PG_EXPORTER_AUTO_DISCOVER_DATABASES=true` was enabled, the exporter scraped **all databases** including system databases (`postgres`, `template0`, `template1`) that don't have Citus extension installed.

## Solution

### 1. Exclude System Databases (Primary Fix)

Added `PG_EXPORTER_EXCLUDE_DATABASES` to both coordinator and worker StatefulSets:

```yaml
- name: PG_EXPORTER_EXCLUDE_DATABASES
  value: "template0,template1,postgres"
```

This prevents the exporter from scraping system databases that:
- Don't have Citus extension installed (missing `pg_dist_*` tables)
- May not have optional extensions like `pg_stat_statements`
- Are templates and shouldn't be monitored for application metrics

### 2. Fixed Custom Queries for Replica Safety

All custom queries that use WAL functions now use conditional execution:

**Pattern for Replica-Safe Queries**:
```sql
SELECT ... FROM (
  -- Primary branch: Run actual query with WAL functions
  SELECT ..., pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) as lag_bytes
  FROM pg_replication_slots
  WHERE NOT pg_is_in_recovery()  -- Only execute on primary
  
  UNION ALL
  
  -- Replica branch: Return dummy data
  SELECT 'replica' as slot_name, 0 as lag_bytes
  WHERE pg_is_in_recovery()  -- Only execute on replicas
) as safe_query
```

**Updated Queries**:
- ✅ `citus_replication_lag` - Returns `state='standby'` on replicas
- ✅ `pg_replication_slots` - Returns `slot_name='none'` on replicas
- ✅ `citus_distributed_queries` - Gracefully handles missing `pg_stat_statements`

### 3. Enhanced Monitoring with Labels

Added constant labels for better metric filtering:

```yaml
- name: PG_EXPORTER_CONSTANT_LABELS
  value: "cluster={{ .Values.clusterName }},citus_group={{ .Values.coordinator.citusGroup }}"
```

All metrics now include:
- `cluster="cituspreprod"` - Cluster identifier
- `citus_group="0"` (coordinator) or `"1"`, `"2"` (workers) - Citus group ID

## How It Works

### Database Exclusion Logic

The `PG_EXPORTER_EXCLUDE_DATABASES` environment variable tells postgres_exporter to skip these databases:
- `template0` - PostgreSQL system template (not connectable)
- `template1` - Default template database (usually empty)
- `postgres` - Default system database (may not have Citus installed)

The exporter will **only scrape user databases** that have Citus extension installed (e.g., `citus`, `skymap`, custom databases).

### Replica-Safe Query Execution

Queries use `pg_is_in_recovery()` to determine node state:
- Returns `true` on replica/standby nodes
- Returns `false` on primary nodes

The `WHERE NOT pg_is_in_recovery()` clause ensures WAL control functions only execute on primaries, preventing "recovery is in progress" errors on replicas.

## Verification

### 1. Check Exporter Logs (Should Be Clean)

```bash
# No "recovery is in progress" errors
kubectl logs cituspreprod-1-2 -c postgres-exporter | grep -i "recovery is in progress"

# No "does not exist" errors
kubectl logs cituspreprod-1-2 -c postgres-exporter | grep -i "does not exist"

# Should show successful metric collection
kubectl logs cituspreprod-1-2 -c postgres-exporter --tail=50
```

Expected clean output:
```
ts=2025-12-03T15:00:00.123Z caller=server.go:74 level=info msg="Established new database connection" fingerprint=cituspreprod-1-2:5432
ts=2025-12-03T15:00:00.456Z caller=server.go:210 level=info msg="Listening on :9187"
```

### 2. Verify Correct Databases Are Being Scraped

```bash
# Check which databases are being scraped
kubectl exec cituspreprod-1-0 -c postgres-exporter -- curl -s localhost:9187/metrics | grep 'pg_up{' | grep datname

# Should only show user databases with Citus:
# pg_up{cluster="cituspreprod",citus_group="1",datname="citus"} 1
# pg_up{cluster="cituspreprod",citus_group="1",datname="skymap"} 1

# Should NOT show:
# pg_up{datname="postgres"} - EXCLUDED
# pg_up{datname="template1"} - EXCLUDED
```

### 3. Verify Replica Metrics Work Correctly

```bash
# Check replication lag on replica (should return 'replica' state, not error)
kubectl exec cituspreprod-1-2 -c postgres-exporter -- curl -s localhost:9187/metrics | grep citus_replication_lag

# Expected output on replica:
# citus_replication_lag_seconds{application_name="replica",client_addr="0.0.0.0",cluster="cituspreprod",citus_group="1",state="standby"} 0
```

### 4. Verify Citus Metrics Are Collected

```bash
# Check Citus-specific metrics (only on databases with Citus installed)
kubectl exec cituspreprod-1-0 -c postgres-exporter -- curl -s localhost:9187/metrics | grep -E "citus_worker_nodes|citus_distributed_tables"

# Should show:
# citus_worker_nodes_is_active{cluster="cituspreprod",citus_group="0",groupid="1",...} 1
# citus_distributed_tables_distributed_table_count{cluster="cituspreprod",citus_group="0"} 5
```

### 5. Test Query Safety Directly

```bash
# Test on a replica - should return 'replica' row, not error
kubectl exec -it cituspreprod-1-2 -- psql -U postgres -d citus -c "
SELECT application_name, state
FROM pg_stat_replication WHERE NOT pg_is_in_recovery()
UNION ALL
SELECT 'replica', 'standby' WHERE pg_is_in_recovery();
"

# On replica, should return:
#  application_name | state
# ------------------+---------
#  replica          | standby
```

## Prometheus Queries

With the new labels and database filtering, you can query metrics effectively:

```promql
# Check which databases are being monitored per group
pg_up{cluster="cituspreprod"}

# Replication lag for specific Citus group (only user databases)
citus_replication_lag_seconds{cluster="cituspreprod",citus_group="1"}

# Identify replicas vs primaries
citus_replication_lag_seconds{state="standby"}    # Replicas
citus_replication_lag_seconds{state="streaming"}  # Primary with active replicas
citus_replication_lag_seconds{state="none"}       # Primary without replicas

# Citus-specific metrics (only available on Citus-enabled databases)
citus_worker_nodes_is_active{cluster="cituspreprod"}
citus_distributed_tables_distributed_table_count{citus_group="0"}  # Coordinator only

# Database connections per Citus group
pg_stat_activity_count{cluster="cituspreprod",citus_group="0"}  # Coordinator
pg_stat_activity_count{cluster="cituspreprod",citus_group="1"}  # Worker 1
```

## Upgrade Instructions

To apply this fix to an existing deployment:

```bash
# 1. Upgrade Helm chart (updates StatefulSets and ConfigMap)
helm upgrade cituspreprod ./helm/citus-cluster --reuse-values

# 2. Restart StatefulSets to reload ConfigMap and environment variables
kubectl rollout restart statefulset cituspreprod-0  # Coordinator
kubectl rollout restart statefulset cituspreprod-1  # Worker 1
kubectl rollout restart statefulset cituspreprod-2  # Worker 2

# 3. Watch rollout progress
kubectl rollout status statefulset cituspreprod-0
kubectl rollout status statefulset cituspreprod-1
kubectl rollout status statefulset cituspreprod-2

# 4. Verify no more errors in logs
kubectl logs -l cluster-name=cituspreprod -c postgres-exporter --tail=100 | grep -i error

# 5. Verify metrics are being collected
kubectl exec cituspreprod-1-0 -c postgres-exporter -- curl -s localhost:9187/metrics | grep pg_up
```

## Configuration Reference

### Environment Variables Added

| Variable | Value | Purpose |
|----------|-------|---------|
| `PG_EXPORTER_EXCLUDE_DATABASES` | `template0,template1,postgres` | Skip system databases without Citus |
| `PG_EXPORTER_CONSTANT_LABELS` | `cluster=X,citus_group=Y` | Add identifying labels to all metrics |
| `PG_EXPORTER_AUTO_DISCOVER_DATABASES` | `true` | Automatically discover and scrape user databases |

### Query Behavior Matrix

| Query | System DB (postgres) | Citus DB (citus) | Replica Node |
|-------|---------------------|------------------|--------------|
| `citus_worker_nodes` | ❌ Skipped (DB excluded) | ✅ Returns worker list | ✅ Works (read-only) |
| `citus_replication_lag` | ❌ Skipped (DB excluded) | ✅ Returns replication status | ✅ Returns `state='standby'` |
| `pg_replication_slots` | ❌ Skipped (DB excluded) | ✅ Returns slot info | ✅ Returns `slot_name='none'` |
| `citus_distributed_queries` | ❌ Skipped (DB excluded) | ✅ Returns query stats (if pg_stat_statements installed) | ✅ Returns zeros if no extension |

## Related Files

- `helm/citus-cluster/templates/configmap-exporter-queries.yaml` - Custom queries with replica safety
- `helm/citus-cluster/templates/statefulset-coordinator.yaml` - Coordinator postgres_exporter config
- `helm/citus-cluster/templates/statefulset-workers.yaml` - Worker postgres_exporter config
- `docs/MONITORING.md` - Complete monitoring setup guide

## References

- [PostgreSQL: Recovery Control Functions](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-RECOVERY-CONTROL)
- [postgres_exporter: Database Discovery](https://github.com/prometheus-community/postgres_exporter#automatically-discover-databases)
- [postgres_exporter: Configuration](https://github.com/prometheus-community/postgres_exporter#environment-variables)
- [Patroni: Replication Monitoring](https://patroni.readthedocs.io/en/latest/replication_modes.html)
