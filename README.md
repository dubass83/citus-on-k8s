# Citus on K8s

A production-ready Citus PostgreSQL cluster running on Kubernetes with Patroni for high availability. Features include:
- StatefulSets for coordinator and worker nodes
- Automatic failover with Patroni
- SSL/TLS support for secure connections
- PostgreSQL extensions support (PostGIS, pg_partman, and more)
- Helm chart for easy deployment

## Table of Contents 

- [Quick Start](#quick-start)
- [Deployment Options](#deployment-options)
- [SSL/TLS Configuration](#ssltls-configuration)
- [PostgreSQL Extensions](#postgresql-extensions)
- [Example Session](#example-session)
- [Configuration](#configuration)
- [Documentation](#documentation)

## Quick Start

The cluster consists of:
- **Coordinator (group 0)**: 3 Pods for high availability
- **Worker groups (1, 2)**: 2 Pods each for distributed data storage

### Complete Example with Kind

    $ kind create cluster
    Creating cluster "kind" ...
     ✓ Ensuring node image (kindest/node:v1.25.3) 🖼
     ✓ Preparing nodes 📦
     ✓ Writing configuration 📜
     ✓ Starting control-plane 🕹️
     ✓ Installing CNI 🔌
     ✓ Installing StorageClass 💾
    Set kubectl context to "kind-kind"
    You can now use your cluster with:

    kubectl cluster-info --context kind-kind

    Thanks for using kind! 😊

    demo@localhost:~/git/patroni/kubernetes$ docker build -f Dockerfile.citus -t patroni-citus-k8s .
    Sending build context to Docker daemon  138.8kB
    Step 1/11 : FROM postgres:16
    ...
    Successfully built 8cd73e325028
    Successfully tagged patroni-citus-k8s:latest

    $ kind load docker-image patroni-citus-k8s
    Image: "" with ID "sha256:8cd73e325028d7147672494965e53453f5540400928caac0305015eb2c7027c7" not yet present on node "kind-control-plane", loading...

    $ kubectl apply -f citus_k8s.yaml
    service/citusdemo-0-config created
    service/citusdemo-1-config created
    service/citusdemo-2-config created
    statefulset.apps/citusdemo-0 created
    statefulset.apps/citusdemo-1 created
    statefulset.apps/citusdemo-2 created
    endpoints/citusdemo-0 created
    service/citusdemo-0 created
    endpoints/citusdemo-1 created
    service/citusdemo-1 created
    endpoints/citusdemo-2 created
    service/citusdemo-2 created
    service/citusdemo-workers created
    secret/citusdemo created
    serviceaccount/citusdemo created
    role.rbac.authorization.k8s.io/citusdemo created
    rolebinding.rbac.authorization.k8s.io/citusdemo created
    clusterrole.rbac.authorization.k8s.io/patroni-k8s-ep-access created
    clusterrolebinding.rbac.authorization.k8s.io/patroni-k8s-ep-access created

    $ kubectl get sts
    NAME          READY   AGE
    citusdemo-0   1/3     6s  # coodinator (group=0)
    citusdemo-1   1/2     6s  # worker (group=1)
    citusdemo-2   1/2     6s  # worker (group=2)

    $ kubectl get pods -l cluster-name=citusdemo -L role
    NAME            READY   STATUS    RESTARTS   AGE    ROLE
    citusdemo-0-0   1/1     Running   0          105s   primary
    citusdemo-0-1   1/1     Running   0          101s   replica
    citusdemo-0-2   1/1     Running   0          96s    replica
    citusdemo-1-0   1/1     Running   0          105s   primary
    citusdemo-1-1   1/1     Running   0          101s   replica
    citusdemo-2-0   1/1     Running   0          105s   primary
    citusdemo-2-1   1/1     Running   0          101s   replica

    $ kubectl exec -ti citusdemo-0-0 -- bash
    postgres@citusdemo-0-0:~$ patronictl list
    + Citus cluster: citusdemo -----------+----------------+---------+----+-------------+-----+------------+-----+
    | Group | Member        | Host        | Role           | State   | TL | Receive LSN | Lag | Replay LSN | Lag |
    +-------+---------------+-------------+----------------+---------+----+-------------+-----+------------+-----+
    |     0 | citusdemo-0-0 | 10.244.0.10 | Leader         | running |  1 |             |     |            |     |
    |     0 | citusdemo-0-1 | 10.244.0.12 | Replica        | running |  1 |   0/40004E8 |   0 |  0/40004E8 |   0 |
    |     0 | citusdemo-0-2 | 10.244.0.14 | Quorum Standby | running |  1 |   0/40004E8 |   0 |  0/40004E8 |   0 |
    |     1 | citusdemo-1-0 | 10.244.0.8  | Leader         | running |  1 |             |     |            |     |
    |     1 | citusdemo-1-1 | 10.244.0.11 | Quorum Standby | running |  1 |   0/40004E8 |   0 |  0/40004E8 |   0 |
    |     2 | citusdemo-2-0 | 10.244.0.9  | Leader         | running |  1 |             |     |            |     |
    |     2 | citusdemo-2-1 | 10.244.0.13 | Quorum Standby | running |  1 |   0/40004E8 |   0 |  0/40004E8 |   0 |
    +-------+---------------+-------------+----------------+---------+----+-------------+-----+------------+-----+

## Deployment Options

### Option 1: Helm Chart Deployment (Recommended)

Use the Helm chart for more flexible configuration:

```bash
# Build and load the image
docker build -f Dockerfile.citus -t patroni-citus-k8s .
kind load docker-image patroni-citus-k8s  # or push to your registry

# Install with Helm
helm install citusdemo ./helm/citus-cluster \
  --namespace default \
  --set image.repository=patroni-citus-k8s \
  --set image.tag=latest

# Or with custom values
helm install citusdemo ./helm/citus-cluster \
  --namespace default \
  --values custom-values.yaml
```

## SSL/TLS Configuration

The cluster supports SSL/TLS encryption for secure communications between all components.

### Quick SSL Setup

```bash
# 1. Generate SSL certificates
./scripts/generate-ssl-certs.sh

# 2. Create Kubernetes secret
kubectl create secret generic citusdemo-ssl-certs \
  --from-file=ca.crt=certs/ca.crt \
  --from-file=server.crt=certs/server.crt \
  --from-file=server.key=certs/server.key \
  --namespace=default

# 3. Deploy with SSL enabled
helm install citusdemo ./helm/citus-cluster \
  --namespace default \
  --set ssl.enabled=true \
  --set ssl.mode=verify-ca
```

### SSL Modes

| Mode | Description | Security Level |
|------|-------------|----------------|
| `prefer` | Try SSL, fall back to non-SSL (default) | Low |
| `require` | Always use SSL (no cert validation) | Medium |
| `verify-ca` | SSL with CA verification | High ⭐ |
| `verify-full` | SSL with CA + hostname verification | Maximum |

### Configuration

In your `values.yaml`:

```yaml
ssl:
  enabled: true
  mode: verify-ca          # or: prefer, require, verify-full
  secretName: citusdemo-ssl-certs
```

**Important Notes:**
- By default, the cluster uses `PGSSLMODE=prefer` (SSL optional)
- For production, use `verify-ca` or `verify-full` with proper certificates
- The Dockerfile must be rebuilt to support dynamic SSL configuration
- See [docs/SSL_SETUP.md](docs/SSL_SETUP.md) for detailed instructions

### Common SSL Issues

#### Certificate Verify Failed

If you see `SSL error: certificate verify failed`:

1. **Quick fix** (development): Use `ssl.mode=prefer` or `ssl.mode=require`
2. **Production fix**: Generate proper certificates with correct SANs
3. **Verify certificates**: 
   ```bash
   openssl verify -CAfile certs/ca.crt certs/server.crt
   openssl x509 -in certs/server.crt -noout -ext subjectAltName
   ```

For detailed troubleshooting, see [docs/SSL_SETUP.md](docs/SSL_SETUP.md#troubleshooting).

## PostgreSQL Extensions

The cluster supports automatic installation of additional PostgreSQL extensions including PostGIS, pg_partman, and others.

### Supported Extensions

The Docker image includes the following pre-installed extensions:
- **PostGIS** (`postgis`, `postgis_topology`) - Geospatial database capabilities
- **pg_partman** - Partition management for time-series and other data
  - **Note**: The pg_partman background worker (`pg_partman_bgw`) is pre-configured in `shared_preload_libraries`
  - This enables automated partition maintenance without manual intervention
  - Additional BGW settings can be configured via `postgresql.conf` (see [pg_partman documentation](https://github.com/pgpartman/pg_partman#setup))
- Any other PostgreSQL 16 compatible extensions available in Debian packages

### Enabling Extensions

Configure extensions in your `values.yaml`:

```yaml
# In values.yaml
additionalExtensions:
  enabled: true
  extensions:
    - postgis
    - postgis_topology
    - pg_partman
    # Add any other extensions here
```

Extensions are installed via a Kubernetes Job after the cluster is ready. The job:
1. Waits for the PostgreSQL cluster to be ready
2. Creates each extension on the coordinator using `CREATE EXTENSION IF NOT EXISTS ... CASCADE`
3. Citus automatically propagates the extensions to all worker nodes

### pg_partman Background Worker Configuration

The pg_partman background worker is pre-configured in `shared_preload_libraries` for automated partition maintenance. To configure the BGW behavior, you can set additional PostgreSQL parameters:

```sql
-- Connect to your database and configure BGW settings
ALTER DATABASE citus SET pg_partman_bgw.interval = 3600;  -- Run maintenance every hour
ALTER DATABASE citus SET pg_partman_bgw.role = 'postgres';  -- Role to run maintenance as
ALTER DATABASE citus SET pg_partman_bgw.dbname = 'citus';  -- Database to run maintenance on
```

These settings control:
- `pg_partman_bgw.interval` - How often maintenance runs (in seconds)
- `pg_partman_bgw.role` - Which database role executes the background worker
- `pg_partman_bgw.dbname` - Which database(s) receive automated partition maintenance

For more details, see the [pg_partman setup documentation](https://github.com/pgpartman/pg_partman#setup).

### Advanced Configuration

```yaml
additionalExtensions:
  enabled: true
  # Maximum attempts to wait for PostgreSQL to be ready
  maxAttempts: 60
  # Delay between retry attempts (seconds)
  retryDelaySeconds: 5
  # Number of times to retry the job on failure
  backoffLimit: 3
  # Extensions to enable
  extensions:
    - postgis
    - postgis_topology
    - pg_partman
```

### Manual Extension Installation

If the automatic job fails, enable extensions manually:

```bash
# Connect to coordinator and create extension
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d citus \
  -c "CREATE EXTENSION IF NOT EXISTS pg_partman CASCADE;"

# Verify extension is installed
kubectl exec -it citusdemo-0-0 -- psql -U postgres -d citus \
  -c "SELECT * FROM pg_available_extensions WHERE name = 'pg_partman';"
```

### Adding Custom Extensions

To add custom extensions not included in the Docker image:

1. **Update the Dockerfile** ([Dockerfile.citus:34-36](Dockerfile.citus#L34-L36)):
   ```dockerfile
   ## Install PostGIS and pg_partman
   && apt-get install -y postgresql-16-postgis-3 postgresql-16-postgis-3-scripts \
   postgresql-16-partman \
   postgresql-16-your-extension \  # Add your extension package
   ```

2. **Add to values.yaml**:
   ```yaml
   additionalExtensions:
     enabled: true
     extensions:
       - postgis
       - pg_partman
       - your_extension
   ```

3. **Rebuild and redeploy**:
   ```bash
   docker build -f Dockerfile.citus -t patroni-citus-k8s:new-version .
   helm upgrade citusdemo ./helm/citus-cluster -f values.yaml
   ```

## Configuration

### Helm Values

Key configuration options in `helm/citus-cluster/values.yaml`:

```yaml
# Cluster configuration
clusterName: citusdemo
coordinator:
  replicas: 3
  
workers:
  - citusGroup: "1"
    replicas: 2
  - citusGroup: "2"
    replicas: 2

# Storage
storage:
  persistentVolume:
    enabled: true
    size: 5Gi

# SSL/TLS
ssl:
  enabled: true
  mode: verify-ca
  secretName: citusdemo-ssl-certs

# PostgreSQL Extensions
additionalExtensions:
  enabled: true
  extensions:
    - postgis
    - postgis_topology
    - pg_partman
```

### Environment Variables

The following PostgreSQL SSL environment variables are automatically configured:

- `PGSSLMODE`: SSL mode (prefer, require, verify-ca, verify-full)
- `PGSSLROOTCERT`: Path to CA certificate
- `PGSSLCERT`: Path to server certificate
- `PGSSLKEY`: Path to server private key

## Documentation

- **[SSL Setup Guide](docs/SSL_SETUP.md)**: Comprehensive SSL/TLS configuration guide
  - Certificate generation
  - Deployment procedures
  - Troubleshooting
  - Production best practices
  - Certificate rotation

## Example Session
     nodeid | groupid |  nodename   | nodeport | noderack | hasmetadata | isactive | noderole  | nodecluster | metadatasynced | shouldhaveshards
    --------+---------+-------------+----------+----------+-------------+----------+-----------+-------------+----------------+------------------
          1 |       0 | 10.244.0.10 |     5432 | default  | t           | t        | primary   | default     | t              | f
          2 |       1 | 10.244.0.8  |     5432 | default  | t           | t        | primary   | default     | t              | t
          3 |       2 | 10.244.0.9  |     5432 | default  | t           | t        | primary   | default     | t              | t
          4 |       0 | 10.244.0.14 |     5432 | default  | t           | t        | secondary | default     | t              | f
          5 |       0 | 10.244.0.12 |     5432 | default  | t           | t        | secondary | default     | t              | f
          6 |       1 | 10.244.0.11 |     5432 | default  | t           | t        | secondary | default     | t              | t
          7 |       2 | 10.244.0.13 |     5432 | default  | t           | t        | secondary | default     | t              | t
    (7 rows)

## Troubleshooting

### Init Container Issues

If pods are stuck with init containers waiting for PostgreSQL:

1. **PostGIS init container**: This has been moved to a post-install Job. If you're using an old version, upgrade to the latest Helm chart.

2. **Permission init container**: Should complete quickly. Check logs:
   ```bash
   kubectl logs <pod-name> -c fix-permissions
   ```

### SSL Connection Errors

If you see SSL certificate verification errors:

```bash
# Check SSL configuration
kubectl exec -it citusdemo-0-0 -- env | grep PGSSL

# Verify certificates are mounted
kubectl exec -it citusdemo-0-0 -- ls -la /etc/ssl/certs/postgresql/

# Check Patroni logs
kubectl logs citusdemo-0-0 | grep -i ssl
```

See [docs/SSL_SETUP.md](docs/SSL_SETUP.md#troubleshooting) for detailed troubleshooting.

### Pod Status

```bash
# Check pod status
kubectl get pods -l cluster-name=citusdemo

# Check Patroni cluster status
kubectl exec -it citusdemo-0-0 -- patronictl list

# Check logs
kubectl logs citusdemo-0-0 --tail=100
```

## Contributing

Contributions are welcome! Please ensure:
- SSL private keys are never committed (`.gitignore` protects this)
- Documentation is updated for new features
- Helm chart values are documented

## Security

- **SSL Certificates**: Never commit `*.key` files to version control
- **Secrets**: Use Kubernetes secrets for sensitive data
- **RBAC**: The cluster uses ServiceAccounts with minimal required permissions
- **Production**: Always use SSL with certificate verification in production

## License

[MIT License]
