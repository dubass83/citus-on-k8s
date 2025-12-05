# Automated Database Setup

This document describes the automated post-deployment initialization system for creating multiple databases in the Citus cluster with full distributed setup and SSL certificate authentication.

## Overview

The Helm chart includes a sophisticated automated database creation system that runs as a Kubernetes Job after deployment. This system ensures proper distributed database setup by following the correct execution order and configuration steps.

## How It Works

### Execution Flow

When you define databases in `additionalDatabases` in your `values.yaml`, a Helm post-install/post-upgrade Job is automatically created that:

1. **Waits for all Patroni groups** (coordinator + all worker groups) to have healthy leaders
2. **Creates database on ALL WORKER NODES first**:
   - Creates the database
   - Enables Citus extension
   - Enables all specified additional extensions
3. **Creates database on COORDINATOR**:
   - Creates the database
   - Enables Citus extension
   - Enables all specified additional extensions
4. **Configures SSL certificate authentication** (if SSL is enabled):
   - Verifies `citus.node_conninfo` is configured
   - Inserts authentication info into `pg_dist_authinfo` for coordinator (nodeid=0)
5. **Registers worker nodes** in Citus metadata using `citus_add_node()`
6. **Runs custom initialization SQL** (if provided)
7. **Sets database-level parameters** (if provided)

### Why This Order Matters

**Workers First, Then Coordinator**: Creating databases on workers before the coordinator ensures that:
- When the coordinator adds workers via `citus_add_node()`, the database already exists on workers
- Extensions are already installed on workers, avoiding authentication issues during CASCADE
- SSL certificate authentication is properly configured before any inter-node communication

**SSL Configuration**: The `pg_dist_authinfo` table stores per-node authentication credentials, allowing Citus to use SSL certificate authentication for inter-node communication. This is essential for production deployments with strict security requirements.

## Configuration

### Basic Example

```yaml
additionalDatabases:
  - name: myapp
    extensions:
      - postgis
      - pg_partman
```

This minimal configuration will:
- Create database `myapp` on all workers and coordinator
- Install Citus, PostGIS, and pg_partman on all nodes
- Register all available workers in the Citus metadata

### Complete Example

```yaml
ssl:
  enabled: true
  mode: verify-ca

additionalDatabases:
  - name: skymap
    owner: postgres
    maxAttempts: 60
    retryDelaySeconds: 5
    backoffLimit: 3

    # Optional: Only use specific worker groups
    workerGroups:
      - "1"
      - "2"

    # Extensions (installed on both workers and coordinator)
    extensions:
      - postgis
      - postgis_topology
      - pg_partman

    # Custom initialization SQL (runs on coordinator after workers are added)
    initSQL: |
      CREATE SCHEMA analytics;
      CREATE ROLE readonly WITH LOGIN PASSWORD 'changeme';
      GRANT CONNECT ON DATABASE skymap TO readonly;

    # Database-level parameters
    parameters:
      timezone: "UTC"
      pg_partman_bgw.dbname: "skymap"
```

### Configuration Options

#### Required Fields

- **`name`**: Database name (required)

#### Optional Fields

- **`owner`**: Database owner (default: `postgres`)
- **`maxAttempts`**: Maximum wait attempts for nodes to be ready (default: `60`)
- **`retryDelaySeconds`**: Seconds between retry attempts (default: `5`)
- **`backoffLimit`**: Job retry limit on failure (default: `3`)

#### Worker Selection

- **`workerGroups`**: Array of worker group IDs to add to this database
  - If not specified, all workers from coordinator metadata are added
  - Use this to create databases that only use a subset of workers
  - Uses service names (e.g., `citusdemo-1`, `citusdemo-2`)

**Example:**
```yaml
workerGroups:
  - "1"  # Only add worker group 1
  - "2"  # Only add worker group 2
  # Worker group 3 will NOT be added to this database
```

#### Extensions

- **`extensions`**: Array of extension names to install
  - Installed on **both** workers and coordinator
  - Always includes `citus` extension automatically
  - Extensions are created with `CASCADE` to handle dependencies

**Example:**
```yaml
extensions:
  - postgis
  - postgis_topology
  - pg_partman
  - hstore
  - pg_trgm
```

#### Custom SQL Initialization

- **`initSQL`**: Multi-line SQL script to run after database setup
  - Runs **only on coordinator** after workers are registered
  - Perfect for creating schemas, roles, tables, and distributed tables
  - Has full access to Citus distributed functions

**Example:**
```yaml
initSQL: |
  -- Create schemas
  CREATE SCHEMA IF NOT EXISTS analytics;
  CREATE SCHEMA IF NOT EXISTS staging;

  -- Create roles
  CREATE ROLE app_user WITH LOGIN PASSWORD 'changeme';
  GRANT CONNECT ON DATABASE mydb TO app_user;

  -- Create distributed table
  CREATE TABLE events (
    event_id BIGSERIAL,
    user_id BIGINT NOT NULL,
    event_data JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (event_id, user_id)
  );
  SELECT create_distributed_table('events', 'user_id');

  -- Create reference table
  CREATE TABLE users (
    user_id BIGINT PRIMARY KEY,
    username TEXT NOT NULL
  );
  SELECT create_reference_table('users');
```

#### Database Parameters

- **`parameters`**: Key-value pairs for database-level configuration
  - Applied using `ALTER DATABASE ... SET`
  - Useful for `pg_partman_bgw` settings, timezone, search_path, etc.

**Example:**
```yaml
parameters:
  timezone: "UTC"
  pg_partman_bgw.dbname: "mydb"
  pg_partman_bgw.interval: "3600"
  search_path: "analytics,public"
```

## SSL Certificate Authentication

### How It Works

When SSL is enabled (`ssl.enabled: true`), the automation system configures `pg_dist_authinfo` to enable certificate-based authentication for Citus inter-node communication.

The system automatically:
1. Verifies that `citus.node_conninfo` includes SSL certificate paths
2. Inserts authentication credentials into `pg_dist_authinfo` for the coordinator (nodeid=0)
3. Uses these credentials for all `citus_add_node()` operations

### pg_dist_authinfo Structure

The automation inserts the following into each new database:

```sql
INSERT INTO pg_dist_authinfo (nodeid, rolename, authinfo)
VALUES (0, 'postgres',
        'password=<superuser_password> sslcert=/etc/ssl/certs/postgresql/server.crt sslkey=/etc/ssl/certs/postgresql/server.key')
ON CONFLICT (nodeid, rolename) DO UPDATE
SET authinfo = EXCLUDED.authinfo;
```

This ensures:
- Coordinator (nodeid=0) uses both password and certificate authentication
- SSL certificates are passed to worker connections
- Authentication works even with `verify-ca` or `verify-full` SSL modes

### Prerequisites for SSL

Before enabling SSL, you must:
1. Generate SSL certificates using `./scripts/generate-ssl-certs.sh`
2. Create Kubernetes secret with certificates
3. Enable SSL in values.yaml

See [SSL_SETUP.md](SSL_SETUP.md) for detailed instructions.

## Deployment

### Initial Deployment

```bash
# 1. Create SSL certificates (if using SSL)
./scripts/generate-ssl-certs.sh

# 2. Create Kubernetes secret
kubectl create secret generic citusdemo-ssl-certs \
  --from-file=ca.crt=certs/ca.crt \
  --from-file=server.crt=certs/server.crt \
  --from-file=server.key=certs/server.key

# 3. Deploy with automated database creation
helm install citusdemo ./helm/citus-cluster \
  -f values.example-automated-setup.yaml
```

### Adding Databases to Existing Cluster

You can add new databases to an already-running cluster:

```bash
# 1. Edit values.yaml to add new database
vim helm/citus-cluster/values.yaml

# 2. Upgrade deployment (triggers post-upgrade hook)
helm upgrade citusdemo ./helm/citus-cluster --reuse-values
```

The Job will:
- Skip existing databases (idempotent)
- Create only the new databases
- Register workers if not already registered

## Monitoring and Troubleshooting

### Check Job Status

```bash
# List all database creation jobs
kubectl get jobs -l job-type=database-creation

# Check specific job
kubectl get job citusdemo-create-db-skymap

# View job logs
kubectl logs job/citusdemo-create-db-skymap
```

### Job Output Interpretation

The job logs show detailed progress:

```
========================================
Creating database: skymap
========================================
PostgreSQL coordinator is ready!

Step 1: Creating database 'skymap' on worker nodes first...
  Configuring worker: citusdemo-1
    Worker citusdemo-1 is ready!
    Creating database 'skymap' on citusdemo-1...
    Database created successfully on citusdemo-1!
    Enabling Citus extension on citusdemo-1...
    Enabling extension postgis on citusdemo-1...
    Worker citusdemo-1 configured successfully!

Step 2: Creating database 'skymap' on coordinator...
  Database 'skymap' created successfully on coordinator!

Step 3: Enabling Citus extension on coordinator...
  Citus extension enabled on coordinator!

Step 4: Enabling additional extensions on coordinator...
  - Enabling extension: postgis
  Additional extensions enabled on coordinator!

Step 5: Configuring SSL certificate authentication (pg_dist_authinfo)...
  Current citus.node_conninfo: sslcert=/etc/ssl/certs/postgresql/server.crt sslkey=/etc/ssl/certs/postgresql/server.key
  ✓ SSL certificate authentication is configured globally
  Configuring authentication for coordinator (nodeid=0)...
  Coordinator authentication configured!

Step 6: Adding worker nodes to Citus metadata...
  Adding worker: citusdemo-1:5432
  Workers added successfully!

Step 7: Running custom initialization SQL...
  Custom SQL executed successfully!

========================================
Database 'skymap' is ready!
========================================
```

### Common Issues

#### Job Fails with "Worker did not become ready"

**Cause**: Worker pods are not healthy or not started.

**Solution**:
```bash
# Check worker pod status
kubectl get pods -l citus-type=worker

# Check specific worker logs
kubectl logs citusdemo-1-0

# Wait for workers to be ready, then retry
kubectl delete job citusdemo-create-db-skymap
helm upgrade citusdemo ./helm/citus-cluster --reuse-values
```

#### "Failed to create extension on worker"

**Cause**: Extension not installed in Docker image or permission issues.

**Solution**:
- Ensure extension packages are installed in [Dockerfile.citus](../Dockerfile.citus)
- Check worker logs for specific error messages
- Verify extension availability: `kubectl exec citusdemo-1-0 -- psql -U postgres -c "\dx available"`

#### "Failed to add worker" Authentication Error

**Cause**: SSL certificate authentication not configured or `.pgpass` missing.

**Solution**:
- Verify SSL is enabled: `ssl.enabled: true`
- Check `citus.node_conninfo`: `kubectl exec citusdemo-0-0 -- psql -U postgres -d skymap -c "SHOW citus.node_conninfo;"`
- If using password auth, ensure `pgpass.enabled: true`
- See [DATABASE_MANAGEMENT_TROUBLESHOOTING.md](DATABASE_MANAGEMENT_TROUBLESHOOTING.md)

#### Job Succeeds but Database Not Created

**Cause**: Database name conflict or job didn't run.

**Solution**:
```bash
# Check if database exists
kubectl exec citusdemo-0-0 -- psql -U postgres -d postgres -c "\l"

# Manually trigger job
kubectl delete job citusdemo-create-db-skymap
helm upgrade citusdemo ./helm/citus-cluster --reuse-values
```

## Manual Verification

After the Job completes, verify the setup:

```bash
# 1. Connect to coordinator
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d skymap

# 2. Check workers are registered
SELECT * FROM citus_get_active_worker_nodes();

# 3. Check pg_dist_authinfo (if SSL enabled)
SELECT nodeid, rolename FROM pg_dist_authinfo;

# 4. Check extensions
\dx

# 5. Test distributed table creation
CREATE TABLE test (id BIGINT PRIMARY KEY, data TEXT);
SELECT create_distributed_table('test', 'id');
```

## Best Practices

### 1. Use Worker Groups for Database Isolation

If you need different databases to use different worker sets:

```yaml
additionalDatabases:
  - name: production_app
    workerGroups: ["1", "2"]  # Use groups 1 and 2

  - name: analytics
    workerGroups: ["3", "4"]  # Use groups 3 and 4 (different hardware)
```

### 2. Configure pg_partman for Time-Series Data

```yaml
additionalDatabases:
  - name: timeseries
    extensions:
      - pg_partman
    parameters:
      pg_partman_bgw.dbname: "timeseries"
      pg_partman_bgw.interval: "3600"  # Run every hour
      pg_partman_bgw.role: "postgres"
```

### 3. Use Reference Tables for Small Lookup Data

In your `initSQL`:

```sql
-- Create reference table (replicated to all workers)
CREATE TABLE countries (
  country_code CHAR(2) PRIMARY KEY,
  country_name TEXT NOT NULL
);
SELECT create_reference_table('countries');

-- Distributed table can join with reference table efficiently
CREATE TABLE users (
  user_id BIGINT PRIMARY KEY,
  country_code CHAR(2) REFERENCES countries(country_code),
  username TEXT
);
SELECT create_distributed_table('users', 'user_id');
```

### 4. Co-locate Related Tables

```sql
-- First table
CREATE TABLE users (user_id BIGINT PRIMARY KEY, ...);
SELECT create_distributed_table('users', 'user_id');

-- Co-located table (same distribution key)
CREATE TABLE posts (post_id BIGINT, user_id BIGINT, ...);
SELECT create_distributed_table('posts', 'user_id', colocate_with => 'users');
```

This ensures joins between `users` and `posts` are local to each worker.

## Advanced Usage

### Multiple Databases with Different Configurations

```yaml
additionalDatabases:
  # Production application database
  - name: app_prod
    workerGroups: ["1", "2"]
    extensions:
      - postgis
      - pg_trgm
    initSQL: |
      CREATE SCHEMA app;
      -- Application tables...
    parameters:
      timezone: "UTC"

  # Analytics database (larger workers)
  - name: analytics
    workerGroups: ["3", "4"]
    extensions:
      - pg_partman
    initSQL: |
      CREATE SCHEMA raw;
      CREATE SCHEMA processed;
      -- Analytics tables with partitioning...
    parameters:
      pg_partman_bgw.dbname: "analytics"
      work_mem: "32MB"

  # Development/staging database (coordinator only)
  - name: dev
    # No workerGroups = uses all available workers
    extensions:
      - postgis
```

### GitOps-Friendly Configuration

Store database definitions in version control:

```bash
# 1. Create database definition file
cat > databases/skymap.yaml <<EOF
- name: skymap
  extensions: [postgis, postgis_topology]
  initSQL: |
    CREATE SCHEMA raw_data;
    CREATE SCHEMA processed_data;
EOF

# 2. Merge with main values
yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
  values.yaml databases/skymap.yaml > values-merged.yaml

# 3. Deploy
helm upgrade citusdemo ./helm/citus-cluster -f values-merged.yaml
```

## Comparison with Manual Setup

### Before (Manual Setup)

```bash
# 1. Wait for cluster
kubectl wait --for=condition=ready pod/citusdemo-0-0

# 2. Create on each worker manually
for i in 1 2; do
  kubectl exec citusdemo-$i-0 -- psql -U postgres -c "CREATE DATABASE mydb"
  kubectl exec citusdemo-$i-0 -- psql -U postgres -d mydb -c "CREATE EXTENSION citus"
done

# 3. Create on coordinator
kubectl exec citusdemo-0-0 -- psql -U postgres -c "CREATE DATABASE mydb"
kubectl exec citusdemo-0-0 -- psql -U postgres -d mydb -c "CREATE EXTENSION citus"

# 4. Configure SSL auth manually
kubectl exec citusdemo-0-0 -- psql -U postgres -d mydb <<EOF
INSERT INTO pg_dist_authinfo (nodeid, rolename, authinfo) VALUES ...
EOF

# 5. Add workers manually
kubectl exec citusdemo-0-0 -- psql -U postgres -d mydb <<EOF
SELECT citus_add_node('citusdemo-1', 5432);
SELECT citus_add_node('citusdemo-2', 5432);
EOF
```

### After (Automated Setup)

```yaml
# values.yaml
additionalDatabases:
  - name: mydb
    extensions: [postgis]
```

```bash
helm install citusdemo ./helm/citus-cluster -f values.yaml
# Done! Database fully configured on all nodes.
```

## See Also

- [DATABASE_MANAGEMENT.md](DATABASE_MANAGEMENT.md) - Manual database management guide
- [SSL_SETUP.md](SSL_SETUP.md) - SSL certificate setup and configuration
- [CERTIFICATE_AUTHENTICATION.md](CERTIFICATE_AUTHENTICATION.md) - Certificate-based authentication details
- [DATABASE_MANAGEMENT_TROUBLESHOOTING.md](DATABASE_MANAGEMENT_TROUBLESHOOTING.md) - Troubleshooting guide
- [../helm/citus-cluster/values.example-automated-setup.yaml](../helm/citus-cluster/values.example-automated-setup.yaml) - Complete example configuration
