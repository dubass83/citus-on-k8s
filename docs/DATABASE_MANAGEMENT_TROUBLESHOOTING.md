# Database Management Troubleshooting Guide

This guide addresses common issues when creating and managing additional databases in Citus clusters based on real-world scenarios.

## Critical Issue: Worker Node Registration

### Problem: DNS Resolution and Authentication Errors

When manually creating databases, you may encounter these errors:

```sql
staging=# SELECT * from citus_add_node('citusstage-1-0', 5432);
ERROR:  connection to the remote node postgres@citusstage-1-0:5432 failed with the following error: 
could not translate host name "citusstage-1-0" to address: Name or service not known

staging=# SELECT * from citus_add_node('10.110.2.189', 5432);
ERROR:  connection to the remote node postgres@10.110.2.189:5432 failed with the following error: 
fe_sendauth: no password supplied
```

### Root Cause Analysis

**Problem 1: Using Pod Names Instead of Service Names**
- ❌ **Wrong**: `citusstage-1-0` (pod name - no DNS record)
- ✅ **Correct**: `citusstage-1` (service name - has DNS record)

**Problem 2: Direct IP Without Authentication**
- When using IP addresses directly, Citus cannot authenticate
- PostgreSQL `pg_hba.conf` requires MD5 auth, but no credentials are provided
- Citus needs proper connection parameters including authentication

### Solution: Use Kubernetes Service Names

Kubernetes creates DNS records for **Services**, not individual Pods. Worker StatefulSets have corresponding Services:

```bash
# From your patronictl output:
# Group | Member         | Host         | Role
#   1   | citusstage-1-0 | 10.110.4.183 | Quorum Standby
#   1   | citusstage-1-1 | 10.110.3.44  | Quorum Standby  
#   1   | citusstage-1-2 | 10.110.2.189 | Leader

# The service name is: citusstage-1 (NOT citusstage-1-0, citusstage-1-1, or citusstage-1-2)
```

**DNS Records Created by Kubernetes**:
- ✅ `citusstage-1.default.svc.cluster.local` → Routes to current Patroni leader (10.110.2.189)
- ✅ `citusstage-1` → Short name within same namespace
- ❌ `citusstage-1-0` → No DNS record (this is a pod name, not a service)

### Correct Manual Registration

#### Method 1: Copy from Existing Database (Recommended)

The workers are already registered in your `citus` database. Simply copy them:

```bash
kubectl exec -it citusstage-0-0 -- bash -c '
export PGPASSWORD="${POSTGRES_PASSWORD}"

# Connect to staging database
psql -U postgres -d staging <<EOF

-- Copy worker registrations from citus database
-- This uses the correct service names and handles authentication automatically
INSERT INTO pg_dist_node (nodeid, groupid, nodename, nodeport, noderack, hasmetadata, isactive, noderole, nodecluster, metadatasynced, shouldhaveshards)
SELECT 
    nextval('\''pg_dist_node_nodeid_seq'\''),
    groupid,
    nodename,
    nodeport,
    noderack,
    hasmetadata,
    isactive,
    noderole,
    nodecluster,
    metadatasynced,
    shouldhaveshards
FROM dblink(
    '\''dbname=citus user=postgres password=${POSTGRES_PASSWORD}'\'',
    '\''SELECT groupid, nodename, nodeport, noderack, hasmetadata, isactive, noderole, nodecluster, metadatasynced, shouldhaveshards FROM pg_dist_node WHERE groupid > 0'\''
) AS t(
    groupid int,
    nodename text,
    nodeport int,
    noderack text,
    hasmetadata boolean,
    isactive boolean,
    noderole text,
    nodecluster text,
    metadatasynced boolean,
    shouldhaveshards boolean
)
ON CONFLICT DO NOTHING;

-- Verify workers
SELECT * FROM citus_get_active_worker_nodes();

EOF
'
```

**Note**: This requires `dblink` extension. If not available, use Method 2.

#### Method 2: Manual Registration with Service Names

```bash
# Connect to any coordinator pod
kubectl exec -it citusstage-0-0 -- bash

# Set password
export PGPASSWORD="${POSTGRES_PASSWORD}"

# Connect to staging database
psql -U postgres -d staging

# Add workers using SERVICE NAMES (not pod names!)
-- For worker group 1
SELECT * FROM citus_add_node('citusstage-1', 5432);

-- For worker group 2 (if you have it)
SELECT * FROM citus_add_node('citusstage-2', 5432);

-- Verify
SELECT * FROM citus_get_active_worker_nodes();
```

#### Method 3: Automated Script

```bash
kubectl exec -it citusstage-0-0 -- bash -c '
export PGPASSWORD="${POSTGRES_PASSWORD}"
DB_NAME="staging"

echo "Registering workers for database: $DB_NAME"

# Get unique service names from citus database
# This extracts just the service name part (e.g., "citusstage-1" from "citusstage-1.default.svc.cluster.local")
WORKER_SERVICES=$(psql -U postgres -d citus -t -A -c "
SELECT DISTINCT 
    CASE 
        WHEN nodename LIKE '\''%.%'\'' THEN split_part(nodename, '\'.'\'', 1)
        ELSE nodename
    END as service_name,
    nodeport
FROM pg_dist_node 
WHERE noderole = '\''primary'\'' AND groupid > 0
ORDER BY service_name;
")

if [ -z "$WORKER_SERVICES" ]; then
    echo "ERROR: No workers found in citus database!"
    exit 1
fi

echo "Found worker services:"
echo "$WORKER_SERVICES"
echo ""

# Add each worker to the target database
echo "$WORKER_SERVICES" | while IFS="|" read -r service_name port; do
    if [ -n "$service_name" ]; then
        echo "Adding worker: ${service_name}:${port}"
        psql -U postgres -d $DB_NAME -c "
            SELECT * FROM citus_add_node('\''${service_name}'\'', ${port})
            ON CONFLICT (nodename, nodeport) DO NOTHING;
        " 2>&1 | grep -v "already exists" || true
    fi
done

echo ""
echo "Verifying worker registration:"
psql -U postgres -d $DB_NAME -c "SELECT * FROM citus_get_active_worker_nodes();"
'
```

## Understanding Worker Service Names

### Service Naming Convention

In your cluster:
- **Cluster name**: `citusstage`
- **Coordinator group**: `0` → Service: `citusstage-0`
- **Worker group 1**: `1` → Service: `citusstage-1`
- **Worker group 2**: `2` → Service: `citusstage-2`

### How Patroni and Kubernetes Route Connections

1. **Service (`citusstage-1`)**: 
   - Kubernetes Service with selector `citus-group: "1"` and `role: primary`
   - Automatically routes to the **current Patroni leader** for that group
   - DNS: `citusstage-1.default.svc.cluster.local`

2. **Patroni Updates Service Labels**:
   - When `citusstage-1-2` becomes leader, Patroni updates its pod label `role: primary`
   - Kubernetes Service automatically routes `citusstage-1` → `10.110.2.189` (citusstage-1-2's IP)

3. **Citus Uses Service Name**:
   - Citus stores `nodename: citusstage-1` in `pg_dist_node`
   - All queries to that worker resolve to current leader
   - Automatic failover without updating Citus metadata!

### Verify Your Service Names

```bash
# List all services for your cluster
kubectl get svc -l cluster-name=citusstage

# Should show:
# NAME                  TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)
# citusstage-0          ClusterIP   10.96.xxx.xxx   <none>        5432/TCP
# citusstage-0-config   ClusterIP   None            <none>        <none>
# citusstage-1          ClusterIP   10.96.xxx.xxx   <none>        5432/TCP
# citusstage-1-config   ClusterIP   None            <none>        <none>
# citusstage-workers    ClusterIP   10.96.xxx.xxx   <none>        5432/TCP

# Test DNS resolution from a pod
kubectl exec -it citusstage-0-0 -- bash -c "
getent hosts citusstage-1
getent hosts citusstage-2
"
```

## Authentication Configuration

### How Citus Authenticates to Workers

Citus uses the connection parameters from `citus.node_conninfo` (set in entrypoint.sh):

```bash
# View current connection settings
kubectl exec -it citusstage-0-0 -- psql -U postgres -d staging -c "SHOW citus.node_conninfo;"

# Should include SSL parameters:
# sslrootcert=/etc/ssl/certs/postgresql/ca.crt 
# sslkey=/etc/ssl/certs/postgresql/server.key 
# sslcert=/etc/ssl/certs/postgresql/server.crt 
# sslmode=verify-ca
```

### Worker pg_hba.conf Configuration

Check worker authentication rules:

```bash
# View pg_hba.conf on a worker
kubectl exec -it citusstage-1-0 -- bash -c "
cat /home/postgres/pgdata/pgroot/data/pg_hba.conf
"

# Should include:
# hostssl all all 0.0.0.0/0 md5
```

This means:
- SSL connections are required
- Password authentication (MD5) is needed
- Citus automatically provides credentials via `citus.node_conninfo`

### Why Direct IP Fails

When you use `citus_add_node('10.110.2.189', 5432)`:
- Citus tries to connect without the SSL parameters
- `pg_hba.conf` requires SSL + password
- Connection fails with "no password supplied"

**Solution**: Always use service names, which trigger proper connection parameter resolution.

## Common Errors and Solutions

### Error: "Name or service not known"

```
ERROR: could not translate host name "citusstage-1-0" to address: Name or service not known
```

**Cause**: Using pod name instead of service name.

**Fix**: Replace pod name with service name:
```sql
-- Wrong
SELECT * FROM citus_add_node('citusstage-1-0', 5432);

-- Correct
SELECT * FROM citus_add_node('citusstage-1', 5432);
```

### Error: "no password supplied"

```
ERROR: connection to the remote node postgres@10.110.2.189:5432 failed with the following error: 
fe_sendauth: no password supplied
```

**Cause 1**: Using IP address bypasses Citus connection parameter resolution.

**Fix 1**: Use service name instead of IP:
```sql
-- Wrong
SELECT * FROM citus_add_node('10.110.2.189', 5432);

-- Correct
SELECT * FROM citus_add_node('citusstage-1', 5432);
```

**Cause 2**: Authentication not properly configured.

**Recommended Solution (v1.4.0+)**: Use **certificate-based authentication** instead of passwords.

This is more secure and eliminates password exposure. See [CERTIFICATE_AUTHENTICATION.md](CERTIFICATE_AUTHENTICATION.md) for full details.

**Quick Fix for Certificate Auth**:

Update `entrypoint.sh` to use certificate authentication:

```yaml
# In entrypoint.sh bootstrap.dcs.postgresql section:
citus.node_conninfo: 'sslrootcert=${PGSSLROOTCERT} sslkey=${PGSSLKEY} sslcert=${PGSSLCERT} sslmode=${PGSSLMODE}'
pg_hba:
  - local all all trust
  - hostssl all postgres 0.0.0.0/0 cert clientcert=verify-full map=cnmap
  - hostssl all all 0.0.0.0/0 md5
  - hostssl replication standby ${POD_IP}/16 md5
pg_ident:
  - cnmap /^.*$ postgres
```

**Alternative (Temporary - Less Secure)**: Add password to `citus.node_conninfo`:

```bash
# For backward compatibility or temporary fix
citus.node_conninfo: '... user=postgres password=${PATRONI_SUPERUSER_PASSWORD}'
```

After updating, rebuild the Docker image and redeploy:

```bash
# Rebuild image
docker build -f Dockerfile.citus -t ghcr.io/dubass83/citus:1.4.0 .
docker push ghcr.io/dubass83/citus:1.4.0

# Update deployment
helm upgrade citusstage ./helm/citus-cluster -f helm/citus-cluster/values.stg.yaml \
  --set image.tag=1.4.0 \
  --reuse-values

# Restart all pods to pick up the new configuration
kubectl rollout restart statefulset citusstage-0
kubectl rollout restart statefulset citusstage-1
```

**Verification**:

```bash
# Check the current citus.node_conninfo setting
kubectl exec -it citusstage-0-0 -- psql -U postgres -d citus -c "SHOW citus.node_conninfo;"

# With cert auth: Should NOT contain password
# With password auth: Should include: user=postgres password=...

# Test connectivity to workers
kubectl exec -it citusstage-0-0 -- psql -U postgres -d citus -c \
  "SELECT * FROM citus_check_cluster_node_health();"
```

### Error: "connection to the remote node postgres@localhost:5432 failed"

```
ERROR: connection to the remote node postgres@localhost:5432 failed
```

**Cause**: Citus extension not enabled, or no workers registered.

**Fix**:
```sql
-- Ensure Citus is enabled
CREATE EXTENSION IF NOT EXISTS citus CASCADE;

-- Check if workers are registered
SELECT * FROM pg_dist_node;

-- If empty, add workers
SELECT * FROM citus_add_node('citusstage-1', 5432);
```

### Error: "node already exists"

```
ERROR: node citusstage-1:5432 already exists
```

**Cause**: Worker already registered (not actually an error).

**Fix**: Check current registrations:
```sql
SELECT * FROM citus_get_active_worker_nodes();
```

If the worker is already registered, you can proceed with creating distributed tables.

## Verification Checklist

After creating a new database and registering workers:

```sql
-- 1. Verify Citus extension is installed
SELECT extname, extversion FROM pg_extension WHERE extname = 'citus';

-- 2. Check worker nodes are registered
SELECT * FROM citus_get_active_worker_nodes();
-- Should show service names like: citusstage-1, citusstage-2

-- 3. Check node metadata
SELECT nodeid, groupid, nodename, nodeport, noderole 
FROM pg_dist_node 
ORDER BY groupid, nodeid;

-- 4. Test worker connectivity
SELECT * FROM citus_check_cluster_node_health();

-- 5. Verify connection settings
SHOW citus.node_conninfo;

-- 6. Test distributed table creation
CREATE TABLE test_table (id int, value text);
SELECT create_distributed_table('test_table', 'id');

-- 7. Verify table distribution
SELECT * FROM citus_tables;

-- 8. Check shard placement
SELECT * FROM citus_shards WHERE table_name = 'test_table'::regclass;
```

## Best Practices

1. **Always Use Service Names**: Never use pod names or IP addresses for worker registration
2. **Copy from citus Database**: The main `citus` database has correct service names already configured
3. **Use Automation**: Prefer the GitOps Helm approach or automated scripts over manual registration
4. **Verify Before Production**: Test distributed table creation after worker registration
5. **Check Patroni Status**: Use `patronictl list` to understand cluster topology
6. **Monitor Connection Health**: Regularly run `citus_check_cluster_node_health()`

## GitOps Approach to Avoid These Issues

To avoid manual registration issues entirely, use the Helm-based GitOps approach:

```yaml
# values.yaml
additionalDatabases:
  - name: staging
    extensions:
      - postgis
      - pg_partman
```

```bash
helm upgrade citusstage ./helm/citus-cluster --reuse-values
```

The automated job will:
1. ✅ Use correct service names from the `citus` database
2. ✅ Handle authentication automatically
3. ✅ Verify connectivity before proceeding
4. ✅ Enable extensions in the correct order
5. ✅ Provide detailed logs for debugging

See [DATABASE_MANAGEMENT.md](DATABASE_MANAGEMENT.md) for complete GitOps setup guide.
