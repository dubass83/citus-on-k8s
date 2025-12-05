# Database Management Guide

This guide explains how to create and manage additional databases in your Citus cluster with all required extensions and proper Citus configuration.

## Table of Contents

- [Understanding the Problem](#understanding-the-problem)
- [GitOps Approach (Recommended)](#gitops-approach-recommended)
- [Manual CLI Approach](#manual-cli-approach)
- [Troubleshooting](#troubleshooting)
- [Advanced Configuration](#advanced-configuration)

## Understanding the Problem

When you create a new database in a Citus cluster, the database doesn't automatically:

1. Have the Citus extension enabled
2. Have worker nodes registered in its metadata
3. Have the proper SSL connection settings configured

This causes errors like:
```
ERROR: connection to the remote node postgres@localhost:5432 failed
```

The error occurs because:
- The Citus extension uses `localhost:5432` as the default connection until properly configured
- Worker nodes are not registered in the new database's `pg_dist_node` table
- Extensions need to be explicitly enabled on the new database

## GitOps Approach (Recommended)

The GitOps approach uses Helm to automatically create and configure databases during deployment.

### Step 1: Configure Database in values.yaml

Edit your `helm/citus-cluster/values.yaml` or create a custom values file:

```yaml
# Additional databases to create with Citus enabled
additionalDatabases:
  - name: skymap
    owner: postgres  # Optional: database owner
    maxAttempts: 60  # Optional: wait attempts (default: 60)
    retryDelaySeconds: 5  # Optional: wait delay (default: 5)
    backoffLimit: 3  # Optional: job retry limit (default: 3)
    
    # Extensions to enable on this database
    extensions:
      - postgis
      - postgis_topology
      - pg_partman
      - timescaledb  # If you have TimescaleDB installed
    
    # Optional: Custom SQL to run after database creation
    initSQL: |
      -- Create schemas
      CREATE SCHEMA IF NOT EXISTS analytics;
      CREATE SCHEMA IF NOT EXISTS staging;
      
      -- Create roles
      CREATE ROLE skymap_reader WITH LOGIN PASSWORD 'reader123';
      CREATE ROLE skymap_writer WITH LOGIN PASSWORD 'writer123';
      
      -- Grant privileges
      GRANT CONNECT ON DATABASE skymap TO skymap_reader;
      GRANT USAGE ON SCHEMA public TO skymap_reader;
      GRANT SELECT ON ALL TABLES IN SCHEMA public TO skymap_reader;
    
    # Optional: Database-level parameter overrides
    parameters:
      pg_partman_bgw.interval: "3600"
      pg_partman_bgw.role: "postgres"
      pg_partman_bgw.dbname: "skymap"
      timezone: "UTC"

  # You can define multiple databases
  - name: analytics
    extensions:
      - postgis
      - pg_partman
```

### Step 2: Deploy or Upgrade

For new deployments:
```bash
helm install citusdemo ./helm/citus-cluster -f your-values.yaml
```

For existing deployments:
```bash
helm upgrade citusdemo ./helm/citus-cluster -f your-values.yaml
```

### Step 3: Verify Database Creation

```bash
# Check job status
kubectl get jobs -l job-type=database-creation

# View job logs
kubectl logs job/citusdemo-create-db-skymap

# Connect to the new database
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d skymap

# Verify Citus is enabled and workers are registered
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d skymap -c "
SELECT * FROM citus_get_active_worker_nodes();
"

# Verify extensions
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d skymap -c "
SELECT extname FROM pg_extension ORDER BY extname;
"
```

### Step 4: Create Distributed Tables

Now you can create distributed tables without errors:

```sql
-- Create a table
CREATE TABLE skymap_points_raw (
    id BIGSERIAL,
    received_at TIMESTAMP NOT NULL,
    data JSONB,
    PRIMARY KEY (id, received_at)
);

-- Distribute the table
SELECT create_distributed_table('skymap_points_raw', 'received_at');

-- Create a reference table (replicated to all nodes)
CREATE TABLE sensors (
    sensor_id INT PRIMARY KEY,
    sensor_name TEXT,
    location GEOMETRY(POINT, 4326)
);
SELECT create_reference_table('sensors');
```

## Manual CLI Approach

If you prefer manual database creation or need to create databases on an existing cluster without redeploying:

### Step 1: Connect to Coordinator

```bash
kubectl exec -it citusdemo-0-0 -- bash
```

### Step 2: Create Database and Enable Citus

```bash
# Set password environment variable
export PGPASSWORD="${POSTGRES_PASSWORD}"

# Create the database
psql -U postgres -d postgres -c "CREATE DATABASE skymap;"

# Enable Citus extension
psql -U postgres -d skymap -c "CREATE EXTENSION IF NOT EXISTS citus CASCADE;"
```

### Step 3: Register Worker Nodes

```bash
# Get list of workers from the main citus database
WORKERS=$(psql -U postgres -d citus -t -A -c "
SELECT nodename, nodeport 
FROM pg_dist_node 
WHERE noderole = 'primary' AND groupid > 0;
")

# Add each worker to the new database
echo "$WORKERS" | while IFS='|' read -r WORKER_HOST WORKER_PORT; do
    echo "Adding worker: ${WORKER_HOST}:${WORKER_PORT}"
    psql -U postgres -d skymap -c "
    SELECT * FROM citus_add_node('${WORKER_HOST}', ${WORKER_PORT});
    "
done
```

### Step 4: Enable Additional Extensions

```bash
# Enable PostGIS
psql -U postgres -d skymap -c "CREATE EXTENSION IF NOT EXISTS postgis CASCADE;"
psql -U postgres -d skymap -c "CREATE EXTENSION IF NOT EXISTS postgis_topology CASCADE;"

# Enable pg_partman
psql -U postgres -d skymap -c "CREATE EXTENSION IF NOT EXISTS pg_partman CASCADE;"

# Verify extensions
psql -U postgres -d skymap -c "SELECT extname FROM pg_extension ORDER BY extname;"
```

### Step 5: Configure Database Parameters (Optional)

```bash
# Set pg_partman background worker configuration
psql -U postgres -d skymap -c "
ALTER DATABASE skymap SET pg_partman_bgw.interval = 3600;
ALTER DATABASE skymap SET pg_partman_bgw.role = 'postgres';
ALTER DATABASE skymap SET pg_partman_bgw.dbname = 'skymap';
"

# Reconnect for settings to take effect
psql -U postgres -d skymap
```

### Step 6: Verify Configuration

```bash
# Check worker nodes
psql -U postgres -d skymap -c "SELECT * FROM citus_get_active_worker_nodes();"

# Check Citus configuration
psql -U postgres -d skymap -c "SHOW citus.node_conninfo;"

# Check extensions
psql -U postgres -d skymap -c "\dx"
```

## Automation Script

For quick manual setup, you can use this one-liner script:

```bash
kubectl exec -it citusdemo-0-0 -- bash -c '
export PGPASSWORD="${POSTGRES_PASSWORD}"
DB_NAME="skymap"

echo "Creating database: $DB_NAME"
psql -U postgres -d postgres -c "CREATE DATABASE $DB_NAME;"

echo "Enabling Citus..."
psql -U postgres -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS citus CASCADE;"

echo "Registering workers..."
psql -U postgres -d citus -t -A -c "SELECT nodename, nodeport FROM pg_dist_node WHERE noderole = '\''primary'\'' AND groupid > 0;" | while IFS="|" read -r host port; do
    psql -U postgres -d $DB_NAME -c "SELECT * FROM citus_add_node('\''$host'\'', $port);" 2>/dev/null || echo "Worker $host already added"
done

echo "Enabling extensions..."
psql -U postgres -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS postgis CASCADE;"
psql -U postgres -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS postgis_topology CASCADE;"
psql -U postgres -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS pg_partman CASCADE;"

echo "Verifying setup..."
psql -U postgres -d $DB_NAME -c "SELECT * FROM citus_get_active_worker_nodes();"
psql -U postgres -d $DB_NAME -c "SELECT extname FROM pg_extension ORDER BY extname;"

echo "Database $DB_NAME is ready!"
'
```

## Troubleshooting

> **📖 Comprehensive Troubleshooting Guide**: For detailed troubleshooting based on real-world scenarios, including DNS resolution issues, authentication errors, and service name configuration, see [DATABASE_MANAGEMENT_TROUBLESHOOTING.md](DATABASE_MANAGEMENT_TROUBLESHOOTING.md).

### Common Issues Quick Reference

### Error: "connection to the remote node postgres@localhost:5432 failed"

**Cause**: Citus extension not enabled on the new database, or workers not registered.

**Solution**:
```sql
-- Enable Citus
CREATE EXTENSION IF NOT EXISTS citus CASCADE;

-- Check if workers are registered
SELECT * FROM citus_get_active_worker_nodes();

-- If no workers, add them (see Step 3 in Manual CLI Approach)
```

### Error: "extension 'postgis' is not available"

**Cause**: Extension not installed in the Docker image.

**Solution**: The extension must be pre-installed in the Docker image. Check `Dockerfile.citus` and rebuild if needed:

```bash
# In Dockerfile.citus, ensure the package is installed:
RUN apt-get update && apt-get install -y \
    postgresql-16-postgis-3 \
    postgresql-16-postgis-3-scripts
```

### Error: "pg_dist_node does not exist"

**Cause**: Citus extension not enabled.

**Solution**:
```sql
CREATE EXTENSION IF NOT EXISTS citus CASCADE;
```

### Workers Not Automatically Registered

**Cause**: Workers need to be explicitly added to each new database.

**Solution**: Workers are registered per-database, not globally. You must add workers to each new database using `citus_add_node()` as shown in Step 3 of the Manual CLI Approach.

**Important**: Always use **service names** (e.g., `citusdemo-1`), not pod names (e.g., `citusdemo-1-0`) or IP addresses. Pod names don't have DNS records and will fail with "Name or service not known" errors. See [DATABASE_MANAGEMENT_TROUBLESHOOTING.md](DATABASE_MANAGEMENT_TROUBLESHOOTING.md) for details.

### SSL Connection Issues

**Cause**: New database inherits SSL settings from the cluster, but connection info may not be properly configured.

**Solution**: Verify Citus connection settings:
```sql
SHOW citus.node_conninfo;

-- Should show SSL settings, e.g.:
-- sslrootcert=/etc/ssl/certs/postgresql/ca.crt sslkey=...
```

## Advanced Configuration

### Creating Multiple Databases with Different Configurations

```yaml
additionalDatabases:
  # OLTP database with high connections
  - name: app_production
    extensions:
      - pg_stat_statements
      - pgcrypto
    parameters:
      max_connections: "500"
      shared_buffers: "256MB"
  
  # Analytics database with PostGIS
  - name: analytics
    extensions:
      - postgis
      - postgis_topology
      - pg_partman
    parameters:
      work_mem: "32MB"
      effective_cache_size: "2GB"
  
  # Time-series database
  - name: timeseries
    extensions:
      - timescaledb
      - pg_partman
    parameters:
      pg_partman_bgw.interval: "1800"
    initSQL: |
      CREATE SCHEMA IF NOT EXISTS metrics;
      CREATE SCHEMA IF NOT EXISTS events;
```

### Database-Level Users and Permissions

Use `initSQL` to create users with specific database permissions:

```yaml
additionalDatabases:
  - name: app_production
    initSQL: |
      -- Create application user
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
          CREATE ROLE app_user WITH LOGIN PASSWORD 'secure_password';
        END IF;
      END
      $$;
      
      -- Grant permissions
      GRANT CONNECT ON DATABASE app_production TO app_user;
      GRANT USAGE, CREATE ON SCHEMA public TO app_user;
      GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
      GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_user;
      
      -- Set default privileges for future tables
      ALTER DEFAULT PRIVILEGES IN SCHEMA public 
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public 
        GRANT USAGE ON SEQUENCES TO app_user;
```

### Dropping Databases

To remove a database (via CLI):

```bash
# Connect to coordinator
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d postgres

# Drop the database
DROP DATABASE skymap;
```

**Note**: When using the GitOps approach, removing a database from `additionalDatabases` will NOT automatically drop it. You must manually drop it if needed.

### Updating Existing Databases

To add extensions to an existing database:

```bash
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d skymap -c "
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
"
```

To modify database parameters:

```bash
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d postgres -c "
ALTER DATABASE skymap SET work_mem = '32MB';
"
```

## Best Practices

1. **Use GitOps for Production**: Define databases in `values.yaml` for reproducibility and version control.

2. **Enable Citus First**: Always enable the Citus extension before creating distributed tables.

3. **Register Workers**: Remember that worker registration is per-database, not global.

4. **Pre-install Extensions**: Extensions must be pre-installed in the Docker image. Use the job only to enable them.

5. **Use Reference Tables**: For small lookup tables, use `create_reference_table()` instead of `create_distributed_table()`.

6. **Test in Staging**: Test database creation and table distribution in a staging environment first.

7. **Monitor Job Execution**: Always check job logs when using the GitOps approach:
   ```bash
   kubectl logs job/citusdemo-create-db-<name>
   ```

8. **Secure Credentials**: Use Kubernetes secrets for database passwords, not plain text in values files.

9. **Database Naming**: Use descriptive names and avoid special characters in database names.

10. **Document Custom SQL**: If using `initSQL`, document the initialization logic for maintainability.

## Connection Examples

### From Application Pod

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  DATABASE_URL: "postgresql://postgres:${PASSWORD}@citusdemo-0:5432/skymap?sslmode=verify-ca"
```

### From External Client (with Port Forward)

```bash
# Port forward to coordinator
kubectl port-forward svc/citusdemo-0 5432:5432

# Connect with psql
PGPASSWORD=zalando psql -h localhost -p 5432 -U postgres -d skymap
```

### From Another Pod (DNS)

```bash
# Full DNS name
psql -h citusdemo-0.default.svc.cluster.local -p 5432 -U postgres -d skymap

# Short name (same namespace)
psql -h citusdemo-0 -p 5432 -U postgres -d skymap
```

## See Also

- [Citus Documentation - Creating a New Database](https://docs.citusdata.com/en/v11.2/admin_guide/cluster_management.html#creating-a-new-database)
- [PostgreSQL Documentation - CREATE DATABASE](https://www.postgresql.org/docs/16/sql-createdatabase.html)
- [SSL_SETUP.md](SSL_SETUP.md) - SSL/TLS configuration guide
- [POSTGRESQL_CONFIG_MIGRATION.md](POSTGRESQL_CONFIG_MIGRATION.md) - PostgreSQL parameter configuration
