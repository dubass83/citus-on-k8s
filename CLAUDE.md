# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a production-ready deployment solution for running distributed Citus PostgreSQL clusters on Kubernetes with Patroni-based high availability. The project is maintained on GitHub at `github.com/dubass83/citus-on-k8s` and uses semantic versioning with automated releases.

**Current Version**: 1.4.2

## Common Commands

### Development Workflow

```bash
# Build the Docker image locally
docker build -f Dockerfile.citus -t patroni-citus-k8s .

# Load image into kind cluster (for local testing)
kind load docker-image patroni-citus-k8s

# Deploy using standalone manifest
kubectl apply -f citus_k8s.yaml

# Deploy using Helm (recommended)
helm install citusdemo ./helm/citus-cluster --namespace default

# Deploy with custom values
helm install citusdemo ./helm/citus-cluster -f custom-values.yaml

# Upgrade existing deployment
helm upgrade citusdemo ./helm/citus-cluster --reuse-values

# Uninstall
helm uninstall citusdemo
kubectl delete pvc -l cluster-name=citusdemo  # if persistent volumes were used
```

### Testing and Verification

```bash
# Check cluster status
kubectl get pods -l cluster-name=citusdemo -L role
kubectl get statefulsets

# View Patroni cluster status (from any pod)
kubectl exec -it citusdemo-0-0 -- patronictl list

# Connect to coordinator database
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d citus

# Check Citus worker nodes
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d citus -c "SELECT * FROM citus_get_active_worker_nodes();"

# View logs
kubectl logs citusdemo-0-0  # Patroni + PostgreSQL logs
kubectl logs citusdemo-0-0 -c fix-permissions  # Init container logs
kubectl logs job/citusdemo-extensions-setup  # Extension installation logs

# Create additional database with Citus enabled
kubectl exec -it citusdemo-0-0 -- bash -c '
export PGPASSWORD="${POSTGRES_PASSWORD}"
DB_NAME="mydb"
psql -U postgres -d postgres -c "CREATE DATABASE $DB_NAME;"
psql -U postgres -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS citus CASCADE;"
psql -U postgres -d citus -t -A -c "SELECT nodename, nodeport FROM pg_dist_node WHERE noderole = '\''primary'\'' AND groupid > 0;" | while IFS="|" read -r host port; do
    psql -U postgres -d $DB_NAME -c "SELECT * FROM citus_add_node('\''$host'\'', $port);"
done
'
```

### SSL/TLS Setup

```bash
# Generate SSL certificates
./scripts/generate-ssl-certs.sh

# Create Kubernetes secret with certificates
kubectl create secret generic citusdemo-ssl-certs \
  --from-file=ca.crt=certs/ca.crt \
  --from-file=server.crt=certs/server.crt \
  --from-file=server.key=certs/server.key \
  --namespace=default

# Deploy with SSL enabled
helm install citusdemo ./helm/citus-cluster \
  --set ssl.enabled=true \
  --set ssl.mode=verify-ca

# Rotate certificates (update secret and restart pods)
kubectl create secret generic citusdemo-ssl-certs \
  --from-file=ca.crt=certs/ca.crt \
  --from-file=server.crt=certs/server.crt \
  --from-file=server.key=certs/server.key \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart statefulset citusdemo-0
kubectl rollout restart statefulset citusdemo-1
```

### CI/CD

```bash
# Trigger release (handled automatically by semantic-release on master/main)
# Commit messages follow conventional commits:
# - feat: new feature (minor version bump)
# - fix: bug fix (patch version bump)
# - BREAKING CHANGE: breaking change (major version bump)

# Manual Helm chart packaging
cd helm
helm package citus-cluster
helm push citus-cluster-*.tgz oci://ghcr.io/dubass83
```

### Monitoring Setup

**NEW!** The cluster now supports **comprehensive monitoring** with Prometheus and Grafana integration.

```bash
# Enable basic monitoring
helm install citusdemo ./helm/citus-cluster \
  --set monitoring.enabled=true \
  --set monitoring.postgresExporter.enabled=true

# Enable with Prometheus Operator (ServiceMonitor)
helm install citusdemo ./helm/citus-cluster \
  --set monitoring.enabled=true \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.serviceMonitor.additionalLabels.prometheus=kube-prometheus

# Deploy with full monitoring stack
helm install citusdemo ./helm/citus-cluster \
  -f helm/citus-cluster/values.example-monitoring-production.yaml

# Verify metrics endpoints
kubectl exec citusdemo-0-0 -- curl localhost:8008/metrics  # Patroni
kubectl exec citusdemo-0-0 -c postgres-exporter -- curl localhost:9187/metrics  # PostgreSQL

# Check ServiceMonitor (if using Prometheus Operator)
kubectl get servicemonitor -l cluster-name=citusdemo
```

**Monitoring Components**:
- **Patroni REST API** (`:8008/metrics`) - Cluster health, failover detection, replication status
- **postgres_exporter** (`:9187/metrics`) - PostgreSQL performance, connections, transactions, cache hits
- **Custom Citus queries** - Worker nodes, shard placement, distributed queries, metadata sync

**Pre-built Grafana Dashboards**:
- **Dashboard 9628**: PostgreSQL Database metrics (import from grafana.com)
- **Dashboard 18870**: Patroni cluster health (import from grafana.com)
- Custom Citus-specific metrics and PromQL examples included

**See**: [docs/MONITORING.md](docs/MONITORING.md) for complete setup guide, metrics reference, alerting rules, and troubleshooting.

## Architecture Overview

### Cluster Topology

The deployment creates a **distributed database cluster** with the following structure:

- **Coordinator (Citus Group 0)**: 3 replicas by default
  - Entry point for all queries
  - Manages distributed query planning
  - StatefulSet: `citusdemo-0`
  - Service: `citusdemo-0` (routes to Patroni primary)

- **Worker Groups (Citus Groups 1, 2, ...)**: 2 replicas per group by default
  - Store sharded data
  - Each group has its own StatefulSet: `citusdemo-1`, `citusdemo-2`, etc.
  - Services: Individual per-group services + `citusdemo-workers` aggregate service

**Key Pattern**: Each Citus group is deployed as a separate StatefulSet with its own Patroni cluster, providing both distributed database capabilities (Citus) and high availability (Patroni).

### Kubernetes Resources Per Group

Each Citus group creates:
1. **StatefulSet**: Manages pods with stable identities
2. **Headless Service** (`-config`): For Patroni DCS using Kubernetes endpoints
3. **ClusterIP Service**: Routes to the current Patroni primary
4. **Endpoints**: Pre-created empty endpoints for Patroni to manage

### Data Flow

**Query Execution**:
1. Client → Coordinator service (`citusdemo-0`)
2. Kubernetes routes to current Patroni primary
3. Citus coordinator parses and plans distributed query
4. Coordinator connects to worker primaries
5. Workers execute query fragments on sharded data
6. Results aggregated at coordinator

**Replication** (per group):
1. Patroni primary accepts writes
2. PostgreSQL streaming replication to replicas
3. Patroni monitors replication lag and manages failover
4. If primary fails, Patroni automatically promotes best replica

### Docker Image Build Process

The [Dockerfile.citus](Dockerfile.citus) builds on `postgres:16` with:

1. **Citus Installation**: Compiled from GitHub source (main branch) to avoid GPG signature issues across architectures
2. **Extensions**: PostGIS 3, pg_partman pre-installed
3. **Patroni**: Installed from GitHub with Kubernetes integration
4. **PostgreSQL Configuration**: Embedded via entrypoint.sh modifications
   - `max_connections: 200`
   - `max_locks_per_transaction: 512` (critical for distributed operations)
   - `shared_preload_libraries: 'pg_partman_bgw'`
   - SSL configuration with environment variable substitution
5. **Entrypoint**: [entrypoint.sh](entrypoint.sh) handles OpenShift compatibility and generates Patroni config dynamically

### Patroni Integration

**Purpose**: Provides automatic failover and HA within each Citus group

**How it works**:
- Uses Kubernetes endpoints/configmaps as Distributed Configuration Store (DCS)
- Performs automatic leader election per group
- Exposes REST API on port 8008 for health checks
- Manages PostgreSQL lifecycle (start, stop, replication)

**Key Environment Variables**:
- `PATRONI_SCOPE`: Cluster name
- `PATRONI_CITUS_GROUP`: Which Citus group (0, 1, 2, ...)
- `PATRONI_KUBERNETES_USE_ENDPOINTS=true`
- `PATRONI_NAME`: Unique pod name

### Helm Chart Structure

Located in [helm/citus-cluster/](helm/citus-cluster/):

**Important Templates**:
- [statefulset-coordinator.yaml](helm/citus-cluster/templates/statefulset-coordinator.yaml): Single coordinator StatefulSet
- [statefulset-workers.yaml](helm/citus-cluster/templates/statefulset-workers.yaml): Loop template for multiple worker groups
- [job-add-ext.yaml](helm/citus-cluster/templates/job-add-ext.yaml): Post-install hook for extension setup
- [config-services.yaml](helm/citus-cluster/templates/config-services.yaml): Headless services for Patroni DCS
- [services.yaml](helm/citus-cluster/templates/services.yaml): ClusterIP services and endpoints

**Key Pattern**: Worker StatefulSets are created via a range loop over `values.workers` array, allowing dynamic scaling of worker groups.

### SSL/TLS Architecture

**Certificate Flow**:
1. Generate certs using [scripts/generate-ssl-certs.sh](scripts/generate-ssl-certs.sh)
2. Store in Kubernetes Secret
3. Init container copies from read-only secret volume to writable location
4. Init container sets ownership (999:999) and permissions
5. Environment variables point PostgreSQL to certificate locations

**SSL Modes** (configured via `ssl.mode` in values.yaml):
- `prefer`: Try SSL, fall back to non-SSL (default)
- `require`: Always SSL, no verification
- `verify-ca`: SSL with CA verification (recommended for production)
- `verify-full`: SSL with CA + hostname verification (maximum security)

**Important**: Certificates use wildcard SANs for Kubernetes DNS patterns. See [docs/SSL_SETUP.md](docs/SSL_SETUP.md) for detailed setup.

### Extension Management

**Pre-installed** (in Docker image):
- PostGIS 3 (`postgis`, `postgis_topology`)
- pg_partman with background worker pre-configured

**Automatic Installation**:
- Helm post-install/post-upgrade job ([job-add-ext.yaml](helm/citus-cluster/templates/job-add-ext.yaml))
- Waits for PostgreSQL readiness
- Creates extensions on coordinator using `CREATE EXTENSION ... CASCADE`
- Citus automatically propagates to all worker nodes
- Configured via `additionalExtensions` in values.yaml

**Key Insight**: Extensions only need to be created on the coordinator; Citus CASCADE handles worker propagation.

## Architectural Decisions

### Why Separate StatefulSets per Citus Group?
- Independent scaling per group
- Isolated failure domains
- Simpler Patroni cluster management
- Flexible resource allocation

### Why Headless Config Services?
- Prevents Kubernetes from deleting Patroni-managed endpoints
- Provides stable DNS for Patroni cluster discovery
- Separates DCS traffic from database traffic

### Why Build Citus from Source?
- Avoids GPG signature issues across architectures
- Ensures latest version from main branch
- Better cross-platform compatibility

### Why SSL via Environment Variables?
- Supports both SSL and non-SSL from same image
- Allows dynamic certificate path configuration
- Easier certificate rotation without rebuilds
- Helm can toggle SSL on/off

### Why Extension Job Instead of Init Container?
- Init containers block pod startup (can timeout)
- Job can wait with longer timeout and retry logic
- Doesn't block cluster startup if extensions fail
- Clearer separation of concerns

## Database Management

### Automated Database Creation (Recommended)

**NEW!** The cluster now supports **fully automated database creation** with proper distributed setup, SSL certificate authentication, and extension installation.

Simply define databases in `values.yaml` and Helm will automatically:
1. Wait for all Patroni groups to be ready
2. Create database on **ALL WORKER NODES first** (with Citus + extensions)
3. Create database on **COORDINATOR** (with Citus + extensions)
4. Configure `pg_dist_authinfo` for SSL certificate authentication (if SSL enabled)
5. Register workers in Citus metadata using `citus_add_node()`
6. Run custom initialization SQL

**Example Configuration**:

```yaml
ssl:
  enabled: true
  mode: verify-ca

additionalDatabases:
  - name: skymap
    extensions:
      - postgis
      - postgis_topology
      - pg_partman
    initSQL: |
      CREATE SCHEMA analytics;
      CREATE TABLE events (event_id BIGSERIAL, user_id BIGINT, created_at TIMESTAMPTZ);
      SELECT create_distributed_table('events', 'user_id');
    parameters:
      pg_partman_bgw.dbname: "skymap"
```

Deploy with: `helm install citusdemo ./helm/citus-cluster -f values.yaml`

**Why This Order Matters**: Creating databases on workers before the coordinator ensures:
- When coordinator adds workers, the database already exists
- Extensions are already installed, avoiding authentication issues
- SSL certificate authentication is configured before inter-node communication

**See**:
- [docs/AUTOMATED_DATABASE_SETUP.md](docs/AUTOMATED_DATABASE_SETUP.md) - Complete automated setup guide
- [helm/citus-cluster/values.example-automated-setup.yaml](helm/citus-cluster/values.example-automated-setup.yaml) - Full example with multiple databases

### Manual Database Creation (Advanced)

For manual setup or troubleshooting, see:
- [docs/DATABASE_MANAGEMENT.md](docs/DATABASE_MANAGEMENT.md) - Manual database management guide
- [docs/DATABASE_MANAGEMENT_TROUBLESHOOTING.md](docs/DATABASE_MANAGEMENT_TROUBLESHOOTING.md) - Troubleshooting DNS and authentication issues

**Important Distributed Table Functions**:
- `create_distributed_table('table_name', 'column')` - for sharded tables
- `create_reference_table('table_name')` - for small lookup tables replicated to all nodes
- `create_distributed_table('table', 'column', colocate_with => 'other_table')` - co-locate related tables

**Critical**: When manually adding workers, always use **service names** (e.g., `citusdemo-1`), not pod names or IPs.

## Scaling Strategies

### Add Worker Groups

Edit [helm/citus-cluster/values.yaml](helm/citus-cluster/values.yaml):

```yaml
workers:
  - citusGroup: "1"
    replicas: 2
  - citusGroup: "2"
    replicas: 2
  - citusGroup: "3"    # New group
    replicas: 2
```

Then upgrade: `helm upgrade citusdemo ./helm/citus-cluster --reuse-values`

**Note**: Adding worker groups requires manual shard rebalancing in Citus (not automated).

### Scale Replicas Within Group

```bash
kubectl scale statefulset citusdemo-1 --replicas=3
```

## Important Configuration Notes

### PostgreSQL Settings

**NEW**: PostgreSQL parameters are now configurable via Helm values! See [helm/citus-cluster/values.yaml](helm/citus-cluster/values.yaml) under `patroni.postgresql.parameters`.

**Default values**:
- `max_connections: 200`
- `max_locks_per_transaction: 512` - critical for distributed operations
- `shared_buffers: 16MB` - should be increased for production (typically 25% of RAM)
- `work_mem: 4MB` - memory per query operation
- `shared_preload_libraries: 'pg_partman_bgw'` - enables automated partition maintenance

**Configuration methods**:
1. **Via Helm values** (for new deployments): Edit `patroni.postgresql.parameters` in values.yaml
2. **Via patronictl** (for running clusters): Use `patronictl edit-config` for zero-downtime changes

See [docs/POSTGRESQL_CONFIG_MIGRATION.md](docs/POSTGRESQL_CONFIG_MIGRATION.md) for migration guide.

### Storage
- Default: emptyDir (ephemeral, for development)
- Production: Set `storage.persistentVolume.enabled: true` in values.yaml

### Security
- Default passwords in values.yaml are for demo only
- SSL private keys never committed (protected by .gitignore)
- RBAC uses least privilege (see [helm/citus-cluster/templates/rbac.yaml](helm/citus-cluster/templates/rbac.yaml))
- Production: Use `ssl.mode: verify-ca` or `verify-full`

### pg_partman Background Worker
The BGW is pre-configured in `shared_preload_libraries`. Configure behavior via:
```sql
ALTER DATABASE citus SET pg_partman_bgw.interval = 3600;  -- Run every hour
ALTER DATABASE citus SET pg_partman_bgw.role = 'postgres';
ALTER DATABASE citus SET pg_partman_bgw.dbname = 'citus';
```

## Troubleshooting

### Pods Not Starting
```bash
# Check pod status and events
kubectl describe pod citusdemo-0-0

# Check init container logs
kubectl logs citusdemo-0-0 -c fix-permissions

# Check Patroni logs
kubectl logs citusdemo-0-0
```

### SSL Certificate Errors
```bash
# Verify SSL environment variables
kubectl exec -it citusdemo-0-0 -- env | grep PGSSL

# Check certificate mount
kubectl exec -it citusdemo-0-0 -- ls -la /etc/ssl/certs/postgresql/

# Validate certificate
openssl verify -CAfile certs/ca.crt certs/server.crt
openssl x509 -in certs/server.crt -noout -ext subjectAltName
```

See [docs/SSL_SETUP.md](docs/SSL_SETUP.md#troubleshooting) for detailed SSL troubleshooting.

### Extension Installation Failures
```bash
# Check job status
kubectl get jobs
kubectl logs job/citusdemo-extensions-setup

# Manual installation
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d citus \
  -c "CREATE EXTENSION IF NOT EXISTS pg_partman CASCADE;"
```

### Failover Testing
```bash
# Delete primary pod (Patroni will auto-promote replica)
kubectl delete pod citusdemo-0-0

# Watch failover progress
watch kubectl exec citusdemo-0-1 -- patronictl list
```

## CI/CD Pipeline

**Platform**: GitHub Actions ([.github/workflows/](.github/workflows/))

**Stages**:
1. **fetch-version**: semantic-release determines next version → `VERSION.txt`
2. **build**:
   - Docker image build with Kaniko → `ghcr.io/dubass83/citus:{VERSION}`
   - Helm chart package → `oci://ghcr.io/dubass83`
3. **release**: semantic-release creates tag, updates CHANGELOG, creates GitHub release

**Versioning** (configured in [.releaserc](.releaserc)):
- Conventional commits (Angular style)
- `feat:` → minor bump
- `fix:`, `docs:`, `refactor:`, etc. → patch bump
- `BREAKING CHANGE:` → major bump

**Triggers**:
- Docker build: Changes to `Dockerfile.*` on master/main or manual in MRs
- Helm package: Changes to `helm/citus-cluster/**/*` on master/main or manual in MRs
- Release: Automatic on master/main after successful build

## File Reference

| File | Purpose |
|------|---------|
| [Dockerfile.citus](Dockerfile.citus) | Builds Citus from source, installs extensions, embeds PostgreSQL config |
| [entrypoint.sh](entrypoint.sh) | Handles OpenShift UIDs, generates Patroni config, launches Patroni |
| [citus_k8s.yaml](citus_k8s.yaml) | Standalone Kubernetes manifest (reference implementation) |
| [helm/citus-cluster/values.yaml](helm/citus-cluster/values.yaml) | Default Helm configuration with inline documentation |
| [helm/citus-cluster/values.stg.yaml](helm/citus-cluster/values.stg.yaml) | Staging environment overrides |
| [scripts/generate-ssl-certs.sh](scripts/generate-ssl-certs.sh) | Generates CA and server certificates with proper SANs |
| [docs/SSL_SETUP.md](docs/SSL_SETUP.md) | Comprehensive SSL/TLS setup and troubleshooting guide |
| [docs/CERTIFICATE_AUTHENTICATION.md](docs/CERTIFICATE_AUTHENTICATION.md) | Certificate-based authentication for Citus inter-node communication (v1.4.0+) |
| [docs/POSTGRESQL_CONFIG_MIGRATION.md](docs/POSTGRESQL_CONFIG_MIGRATION.md) | Migration guide from hardcoded to dynamic PostgreSQL configuration |
| [docs/AUTOMATED_DATABASE_SETUP.md](docs/AUTOMATED_DATABASE_SETUP.md) | **NEW!** Automated database creation with workers-first execution and SSL authentication |
| [docs/DATABASE_MANAGEMENT.md](docs/DATABASE_MANAGEMENT.md) | Manual guide for creating and managing additional databases with Citus |
| [docs/DATABASE_MANAGEMENT_TROUBLESHOOTING.md](docs/DATABASE_MANAGEMENT_TROUBLESHOOTING.md) | Troubleshooting DNS, authentication, and worker registration issues |
| [.gitlab-ci.yml](.gitlab-ci.yml) | CI/CD pipeline with semantic versioning |
| [.releaserc](.releaserc) | Semantic-release configuration |
| [helm/citus-cluster/values.example-with-databases.yaml](helm/citus-cluster/values.example-with-databases.yaml) | Example configuration showing how to create multiple databases (manual approach) |
| [helm/citus-cluster/values.example-automated-setup.yaml](helm/citus-cluster/values.example-automated-setup.yaml) | **NEW!** Complete example with automated database creation, SSL, and distributed tables |
| [docs/MONITORING.md](docs/MONITORING.md) | **NEW!** Comprehensive monitoring guide with Prometheus and Grafana integration |
| [helm/citus-cluster/values.example-monitoring-basic.yaml](helm/citus-cluster/values.example-monitoring-basic.yaml) | Example: Basic monitoring setup for standalone Prometheus |
| [helm/citus-cluster/values.example-monitoring-operator.yaml](helm/citus-cluster/values.example-monitoring-operator.yaml) | Example: Monitoring with Prometheus Operator (ServiceMonitor) |
| [helm/citus-cluster/values.example-monitoring-podmonitor.yaml](helm/citus-cluster/values.example-monitoring-podmonitor.yaml) | Example: Monitoring with PodMonitor for direct pod scraping |
| [helm/citus-cluster/values.example-monitoring-production.yaml](helm/citus-cluster/values.example-monitoring-production.yaml) | Example: Complete production monitoring setup with SSL and HA |
| [helm/citus-cluster/templates/configmap-exporter-queries.yaml](helm/citus-cluster/templates/configmap-exporter-queries.yaml) | Custom Citus-specific metrics for postgres_exporter |
| [helm/citus-cluster/templates/servicemonitor.yaml](helm/citus-cluster/templates/servicemonitor.yaml) | ServiceMonitor CRD for Prometheus Operator integration |
| [helm/citus-cluster/templates/podmonitor.yaml](helm/citus-cluster/templates/podmonitor.yaml) | PodMonitor CRD for direct pod-level metric scraping |
| [helm/citus-cluster/templates/dashboard-patroni.yaml](helm/citus-cluster/templates/dashboard-patroni.yaml) | Basic Patroni dashboard template |
| [helm/citus-cluster/templates/dashboard-postgresql.yaml](helm/citus-cluster/templates/dashboard-postgresql.yaml) | Dashboard import guide with PromQL examples and alerting rules |

## Development Patterns

### When Modifying PostgreSQL Configuration

**IMPORTANT**: Do NOT edit `postgresql.conf` directly or modify the sed commands in the Dockerfile. Patroni manages PostgreSQL configuration through its DCS (Distributed Configuration Store), and direct file edits will be overwritten.

#### Recommended Approach 1: Dynamic Configuration (Preferred)

Use `patronictl` to modify settings on a running cluster without rebuilding:

```bash
# Connect to any pod in the cluster
kubectl exec -it citusdemo-0-0 -- bash

# Edit cluster configuration (opens editor)
patronictl edit-config citusdemo

# In the editor, add parameters under bootstrap.dcs.postgresql.parameters:
# bootstrap:
#   dcs:
#     postgresql:
#       parameters:
#         max_connections: 300
#         shared_buffers: 256MB
#         work_mem: 16MB

# Apply changes to the cluster
patronictl reload citusdemo

# For parameters requiring restart (like shared_buffers):
patronictl restart citusdemo --role replica  # Restart replicas first
patronictl restart citusdemo --role master   # Then restart primary
```

**Note**: Changes made via `patronictl edit-config` persist in the DCS and apply to all nodes in the cluster.

#### Recommended Approach 2: Helm Values (Implemented - For New Deployments)

**This approach is now fully implemented in the codebase!**

Configure PostgreSQL parameters directly in [helm/citus-cluster/values.yaml](helm/citus-cluster/values.yaml):

```yaml
patroni:
  postgresql:
    parameters:
      # Connection Settings
      max_connections: 300  # Default: 200

      # Memory Settings
      shared_buffers: 256MB              # Default: 16MB
      work_mem: 16MB                     # Default: 4MB
      maintenance_work_mem: 128MB        # Default: 64MB
      effective_cache_size: 1GB          # Default: 128MB
      wal_buffers: 16MB                  # Default: 16MB

      # Locking
      max_locks_per_transaction: 1024    # Default: 512

      # Query Planner
      random_page_cost: 1.1              # Default: 1.1 (for SSD)
      checkpoint_completion_target: 0.9  # Default: 0.9

      # Extensions
      shared_preload_libraries: 'pg_partman_bgw'
```

**How it works**:
1. Values are passed as environment variables to pods (see [statefulset-coordinator.yaml](helm/citus-cluster/templates/statefulset-coordinator.yaml))
2. [entrypoint.sh](entrypoint.sh) reads these environment variables with defaults
3. Parameters are written to Patroni's bootstrap DCS configuration
4. Changes require Helm upgrade and pod restart (for restart-required parameters)

**To modify parameters**:
```bash
# Edit values.yaml with your desired parameters
vim helm/citus-cluster/values.yaml

# Upgrade the cluster
helm upgrade citusdemo ./helm/citus-cluster --reuse-values

# For restart-required parameters, restart pods
kubectl rollout restart statefulset citusdemo-0
kubectl rollout restart statefulset citusdemo-1
kubectl rollout restart statefulset citusdemo-2
```

#### Implementation Status

✅ **Fully Implemented!** The codebase now supports dynamic PostgreSQL configuration via Helm values.

**What was changed**:
1. ✅ [entrypoint.sh](entrypoint.sh) - Refactored to read parameters from environment variables
2. ✅ [values.yaml](helm/citus-cluster/values.yaml) - Added `patroni.postgresql.parameters` section
3. ✅ [StatefulSet templates](helm/citus-cluster/templates/) - Pass parameters as environment variables
4. ✅ [Dockerfile.citus](Dockerfile.citus) - Removed hardcoded sed commands for parameters

**Migration Guide**: See [docs/POSTGRESQL_CONFIG_MIGRATION.md](docs/POSTGRESQL_CONFIG_MIGRATION.md) for detailed migration instructions.

#### Parameters Requiring PostgreSQL Restart

Some parameters require a restart to take effect:
- `shared_buffers`
- `max_connections`
- `shared_preload_libraries`
- `max_locks_per_transaction`

Patroni handles restarts gracefully with zero downtime when using `patronictl restart --role replica` followed by `--role master`.

### When Adding New Extensions
1. Update [Dockerfile.citus](Dockerfile.citus) to install Debian package
2. Add extension name to `additionalExtensions.extensions` in values.yaml
3. Rebuild and redeploy

### When Changing Citus Topology
- Edit `workers` array in values.yaml
- Add/remove worker groups as needed
- Run `helm upgrade` to apply changes
- Remember: Shard rebalancing is manual

### When Updating Helm Templates
- Test with `helm template` before applying
- Use `helm diff` plugin to preview changes
- Remember: StatefulSet rolling updates restart pods
