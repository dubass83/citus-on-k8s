# PostgreSQL Configuration Migration Guide

This guide explains how to migrate from the old hardcoded PostgreSQL configuration approach to the new dynamic configuration system using Patroni's DCS and Helm values.

## What Changed?

### Before (Old Approach)
- PostgreSQL parameters were hardcoded in [Dockerfile.citus](../Dockerfile.citus) using `sed` commands
- Required rebuilding Docker image for any configuration change
- Parameters were set only during cluster bootstrap
- Not following Patroni best practices

### After (New Approach)
- PostgreSQL parameters configured via Helm `values.yaml`
- Environment variables passed to pods
- Patroni manages parameters in DCS (Distributed Configuration Store)
- Can be changed without rebuilding images
- Supports both bootstrap configuration and runtime changes

## Migration Paths

### Path 1: For Existing Clusters (No Downtime)

If you have an existing cluster and want to change PostgreSQL parameters without redeploying:

#### Step 1: Use `patronictl edit-config`

```bash
# Connect to any pod in the cluster
kubectl exec -it citusdemo-0-0 -- bash

# Edit the cluster configuration
patronictl edit-config citusdemo
```

This opens an editor (typically vi/vim). You'll see a YAML configuration like:

```yaml
loop_wait: 10
postgresql:
  parameters:
    max_connections: 200
    # ... other parameters
  pg_hba:
    - host all all 0.0.0.0/0 md5
    # ... other rules
  use_pg_rewind: true
retry_timeout: 10
ttl: 30
```

#### Step 2: Add or Modify Parameters

Add your desired parameters under `postgresql.parameters`:

```yaml
postgresql:
  parameters:
    max_connections: 300              # Changed from 200
    max_locks_per_transaction: 1024   # Changed from 512
    shared_buffers: 256MB             # Changed from 16MB
    work_mem: 16MB                    # New parameter
    maintenance_work_mem: 128MB       # New parameter
    effective_cache_size: 1GB         # New parameter
```

#### Step 3: Apply Changes

Save and exit the editor. Patroni will show which changes require a restart:

```
---
+++
@@ -1,5 +1,8 @@
 postgresql:
   parameters:
-    max_connections: 200
+    max_connections: 300
+    shared_buffers: 256MB
```

#### Step 4: Reload or Restart

**For parameters that don't require restart** (like `work_mem`, `max_connections` in some cases):
```bash
patronictl reload citusdemo
```

**For parameters requiring restart** (like `shared_buffers`, `max_locks_per_transaction`):
```bash
# Restart replicas first (zero downtime)
patronictl restart citusdemo --role replica

# Then restart the primary (triggers failover, zero downtime)
patronictl restart citusdemo --role master
```

**Repeat for all worker groups**:
```bash
# For worker group 1
kubectl exec -it citusdemo-1-0 -- bash
patronictl edit-config citusdemo
patronictl restart citusdemo --role replica
patronictl restart citusdemo --role master

# For worker group 2
kubectl exec -it citusdemo-2-0 -- bash
patronictl edit-config citusdemo
patronictl restart citusdemo --role replica
patronictl restart citusdemo --role master
```

**Important**: All groups (coordinator and workers) share the same Patroni scope and DCS configuration, so editing on one pod affects all groups. However, restarts must be done per group.

---

### Path 2: For New Deployments

If you're deploying a new cluster with the updated codebase:

#### Step 1: Update values.yaml

Edit [helm/citus-cluster/values.yaml](../helm/citus-cluster/values.yaml):

```yaml
patroni:
  postgresql:
    parameters:
      # Connection Settings
      max_connections: 300  # Adjust as needed

      # Memory Settings (adjust based on available RAM)
      shared_buffers: 256MB              # Typically 25% of RAM
      work_mem: 16MB
      maintenance_work_mem: 128MB
      effective_cache_size: 1GB          # Typically 50-75% of RAM
      wal_buffers: 16MB

      # Locking
      max_locks_per_transaction: 1024

      # Query Planner
      random_page_cost: 1.1
      checkpoint_completion_target: 0.9

      # Extensions
      shared_preload_libraries: 'pg_partman_bgw'
```

#### Step 2: Deploy with Helm

```bash
# Build new image (includes updated entrypoint.sh)
docker build -f Dockerfile.citus -t patroni-citus-k8s:latest .

# Load to kind (if using local cluster)
kind load docker-image patroni-citus-k8s:latest

# Deploy
helm install citusdemo ./helm/citus-cluster \
  --namespace default \
  -f custom-values.yaml
```

#### Step 3: Verify Configuration

```bash
# Check that environment variables are set
kubectl exec -it citusdemo-0-0 -- env | grep PATRONI_POSTGRESQL

# Verify parameters in PostgreSQL
kubectl exec -it citusdemo-0-0 -- psql -U postgres -c "SHOW max_connections;"
kubectl exec -it citusdemo-0-0 -- psql -U postgres -c "SHOW shared_buffers;"
```

---

### Path 3: Migrating Existing Cluster to New Image

If you have an existing cluster and want to migrate to the new Helm-configurable approach:

#### Step 1: Update values.yaml

Add the `patroni.postgresql.parameters` section with your desired configuration (see Path 2, Step 1).

#### Step 2: Build and Push New Image

```bash
# Build image with new entrypoint.sh
docker build -f Dockerfile.citus -t patroni-citus-k8s:v1.5.0 .

# Push to registry (or load to kind)
docker tag patroni-citus-k8s:v1.5.0 ghcr.io/dubass83/citus:v1.5.0
docker push ghcr.io/dubass83/citus:v1.5.0
```

#### Step 3: Upgrade Cluster with Helm

```bash
helm upgrade citusdemo ./helm/citus-cluster \
  --namespace default \
  --set image.tag=v1.5.0 \
  -f custom-values.yaml \
  --reuse-values
```

This will trigger a rolling update of all StatefulSets.

#### Step 4: Verify After Upgrade

```bash
# Check pod image versions
kubectl get pods -l cluster-name=citusdemo -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Verify Patroni configuration includes new parameters
kubectl exec -it citusdemo-0-0 -- patronictl show-config

# Verify PostgreSQL settings
kubectl exec -it citusdemo-0-0 -- psql -U postgres -c "SELECT name, setting, unit FROM pg_settings WHERE name IN ('max_connections', 'shared_buffers', 'work_mem');"
```

---

## Common PostgreSQL Parameters

### Parameters Requiring Restart

These parameters require a PostgreSQL restart to take effect:

- `shared_buffers`
- `max_connections`
- `shared_preload_libraries`
- `max_locks_per_transaction`
- `max_prepared_transactions`
- `max_worker_processes`
- `wal_level`

**Restart command**:
```bash
patronictl restart citusdemo --role replica  # Restart replicas first
patronictl restart citusdemo --role master   # Then primary
```

### Parameters Not Requiring Restart

These can be changed with just a reload:

- `work_mem`
- `maintenance_work_mem`
- `effective_cache_size`
- `random_page_cost`
- `checkpoint_completion_target`
- `log_*` parameters (logging configuration)

**Reload command**:
```bash
patronictl reload citusdemo
```

---

## Production Recommendations

### Memory Configuration

For a pod with **8GB RAM**:

```yaml
shared_buffers: 2GB              # 25% of RAM
work_mem: 32MB                   # Per query operation
maintenance_work_mem: 512MB      # For VACUUM, CREATE INDEX, etc.
effective_cache_size: 6GB        # 75% of RAM (OS cache estimate)
wal_buffers: 16MB                # WAL write buffer
```

For a pod with **16GB RAM**:

```yaml
shared_buffers: 4GB
work_mem: 64MB
maintenance_work_mem: 1GB
effective_cache_size: 12GB
wal_buffers: 16MB
```

### Connection Settings

```yaml
max_connections: 200              # Or higher based on workload
max_locks_per_transaction: 1024   # Critical for Citus distributed operations
```

### Performance Tuning

```yaml
random_page_cost: 1.1                     # Lower for SSD (default 4.0 is for HDD)
effective_io_concurrency: 200             # Higher for SSD
checkpoint_completion_target: 0.9         # Spread out checkpoint I/O
default_statistics_target: 100            # Query planner statistics
```

### Citus-Specific

```yaml
shared_preload_libraries: 'pg_partman_bgw'  # Must include pg_partman_bgw
citus.max_intermediate_result_size: 1GB     # For large distributed queries
```

---

## Troubleshooting

### Changes Not Applied

**Issue**: Modified values.yaml but parameters unchanged in PostgreSQL.

**Solution**:
1. Check environment variables are set:
   ```bash
   kubectl exec -it citusdemo-0-0 -- env | grep PATRONI_POSTGRESQL
   ```
2. Verify Helm values were applied:
   ```bash
   helm get values citusdemo
   ```
3. Check if pods were restarted after Helm upgrade:
   ```bash
   kubectl get pods -l cluster-name=citusdemo
   ```

### Parameters Reverted After Restart

**Issue**: Used `patronictl edit-config` but parameters reverted after pod restart.

**Explanation**: This happens when:
- Environment variables override DCS settings
- Bootstrap parameters conflict with DCS

**Solution**: Ensure Helm values.yaml matches your desired DCS configuration, or remove the environment variable overrides.

### Different Parameters on Different Pods

**Issue**: Coordinator and workers have different PostgreSQL parameters.

**Solution**: All pods in the same Patroni scope should share DCS configuration. Check:
```bash
kubectl exec -it citusdemo-0-0 -- patronictl show-config
kubectl exec -it citusdemo-1-0 -- patronictl show-config
```

If they differ, use `patronictl edit-config` to set consistent parameters.

---

## Rollback Plan

If you need to rollback to the old hardcoded approach:

### Step 1: Revert Code Changes

```bash
git revert <commit-hash>  # Revert the refactoring commits
```

### Step 2: Rebuild Image

```bash
docker build -f Dockerfile.citus -t patroni-citus-k8s:old-version .
```

### Step 3: Downgrade Helm Release

```bash
helm rollback citusdemo <revision-number>
```

Or deploy with old image:

```bash
helm upgrade citusdemo ./helm/citus-cluster \
  --set image.tag=old-version \
  --reuse-values
```

---

## Testing Checklist

Before migrating production clusters, test in staging:

- [ ] Deploy new cluster with custom parameters in values.yaml
- [ ] Verify parameters are applied: `SHOW <parameter>;`
- [ ] Test `patronictl edit-config` for runtime changes
- [ ] Test `patronictl reload` for reload-able parameters
- [ ] Test `patronictl restart` for restart-requiring parameters
- [ ] Verify zero-downtime failover during restarts
- [ ] Test Helm upgrade with different values.yaml
- [ ] Verify parameters persist after pod restart
- [ ] Test rollback procedure

---

## Additional Resources

- [Patroni Dynamic Configuration Docs](https://patroni.readthedocs.io/en/latest/dynamic_configuration.html)
- [PostgreSQL Configuration Docs](https://www.postgresql.org/docs/16/runtime-config.html)
- [Citus Configuration Docs](https://docs.citusdata.com/en/stable/admin_guide/cluster_management.html)
- [Broadcom Knowledge Base: PostgreSQL Parameters in Patroni](https://knowledge.broadcom.com/external/article/295226/)

---

## Summary

| Aspect | Old Approach | New Approach |
|--------|-------------|--------------|
| **Configuration Location** | Dockerfile.citus (sed commands) | values.yaml + entrypoint.sh |
| **Change Requires** | Image rebuild | Helm upgrade or patronictl |
| **Flexibility** | Low (hardcoded) | High (dynamic) |
| **Best Practice** | ❌ Not Patroni-native | ✅ Patroni DCS-based |
| **Runtime Changes** | ❌ Not possible | ✅ Via patronictl |
| **Cluster Consistency** | ⚠️ Manual sync | ✅ Automatic via DCS |

The new approach follows Patroni best practices and provides much greater flexibility for managing PostgreSQL configuration in production environments.
