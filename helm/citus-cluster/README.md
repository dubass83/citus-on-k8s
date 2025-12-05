# Citus Cluster Helm Chart

A production-ready Helm chart for deploying a Citus distributed PostgreSQL cluster with Patroni on Kubernetes.

## Features

- **High Availability**: Patroni-managed automatic failover
- **Distributed Architecture**: Coordinator and worker nodes for horizontal scaling
- **SSL/TLS Support**: Secure communications with certificate management
- **PostgreSQL Extensions**: Automatic installation of PostGIS, pg_partman, and other extensions
- **Persistent Storage**: Optional persistent volumes for data durability
- **RBAC**: Proper Kubernetes security with ServiceAccounts and Roles
- **Flexible Configuration**: Customizable via Helm values

## Description

This chart deploys a Citus cluster consisting of:
- **Coordinator group** (citus-group-0): 3 replicas by default for high availability
- **Worker groups** (citus-group-1, citus-group-2): 2 replicas each by default for distributed data
- **Patroni**: Automatic leader election and failover management
- **RBAC resources**: ServiceAccount, Roles, and RoleBindings for Kubernetes integration
- **Optional SSL/TLS**: Encrypted connections between all components
- **Optional Extensions**: PostgreSQL extensions (PostGIS, pg_partman, etc.)

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- A Docker image built from `Dockerfile.citus` (default: `patroni-citus-k8s`)

## Building the Docker Image

Before installing the chart, build the required Docker image:

```bash
# From the repository root
docker build -f Dockerfile.citus -t patroni-citus-k8s:latest .

# For local Kubernetes (kind/minikube)
kind load docker-image patroni-citus-k8s:latest
# or
minikube image load patroni-citus-k8s:latest

# For remote registry
docker tag patroni-citus-k8s:latest your-registry/patroni-citus-k8s:latest
docker push your-registry/patroni-citus-k8s:latest
```

## Installation

### Install with default values

```bash
helm install my-citus-cluster ./helm/citus-cluster
```

### Install with custom values

```bash
helm install my-citus-cluster ./helm/citus-cluster -f my-values.yaml
```

### Install to a specific namespace

```bash
kubectl create namespace citus
helm install my-citus-cluster ./helm/citus-cluster -n citus
```

**Note:** If installing to a namespace other than `default`, update the `namespace` value in your `values.yaml` file to match your target namespace for proper ClusterRoleBinding configuration.

## Configuration

The following table lists the main configurable parameters of the chart and their default values.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `clusterName` | Name of the Citus cluster | `citusdemo` |
| `image.repository` | Docker image repository | `patroni-citus-k8s` |
| `image.tag` | Docker image tag | `latest` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `coordinator.enabled` | Enable coordinator deployment | `true` |
| `coordinator.replicas` | Number of coordinator replicas | `3` |
| `workers` | Array of worker group configurations | See values.yaml |
| `patroni.superuser.password` | Superuser password (when secret.create=true) | `zalando` |
| `patroni.replication.password` | Replication password (when secret.create=true) | `rep-pass` |
| `secret.create` | Create secret or use existing | `true` |
| `secret.name` | Name of secret to create or use | `citusdemo` |
| `secret.keys.superuserPassword` | Key name for superuser password | `superuser-password` |
| `secret.keys.replicationPassword` | Key name for replication password | `replication-password` |
| `storage.persistentVolume.enabled` | Enable persistent volumes | `false` |
| `storage.persistentVolume.size` | Size of persistent volume | `5Gi` |
| `namespace` | Namespace for ClusterRoleBinding | `default` |
| `ssl.enabled` | Enable SSL/TLS with proper certificates | `false` |
| `ssl.mode` | SSL mode (prefer, require, verify-ca, verify-full) | `verify-ca` |
| `ssl.secretName` | Name of secret containing SSL certificates | `citusdemo-ssl-certs` |
| `additionalExtensions.enabled` | Enable automatic extension installation | `false` |
| `additionalExtensions.maxAttempts` | Max connection attempts for extension job | `60` |
| `additionalExtensions.retryDelaySeconds` | Delay between retry attempts | `5` |
| `additionalExtensions.backoffLimit` | Number of job retry attempts | `3` |
| `additionalExtensions.enableOnWorkers` | [DEPRECATED] Enable on workers (Citus auto-propagates) | `false` |
| `additionalExtensions.extensions` | List of extensions to install | `[postgis, postgis_topology, pg_partman]` |

See `values.yaml` for the full list of configurable parameters.

## Storage Configuration

By default, the chart uses `emptyDir` volumes for demonstration purposes. For production use, enable persistent volumes:

```yaml
storage:
  persistentVolume:
    enabled: true
    storageClass: "your-storage-class"
    size: 10Gi
```

## Worker Groups

You can customize the number and configuration of worker groups:

```yaml
workers:
  - citusGroup: "1"
    citusType: worker
    replicas: 3
  - citusGroup: "2"
    citusType: worker
    replicas: 3
  - citusGroup: "3"
    citusType: worker
    replicas: 2
```

## SSL/TLS Configuration

The chart supports SSL/TLS encryption for all PostgreSQL connections, including client connections, replication, and Citus distributed queries.

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

# 3. Install with SSL enabled
helm install my-citus-cluster ./helm/citus-cluster \
  --set ssl.enabled=true \
  --set ssl.mode=verify-ca
```

### SSL Modes

| Mode | Description | Certificate Validation | Recommended For |
|------|-------------|------------------------|-----------------|
| `prefer` | Try SSL, fall back to non-SSL | None | Development (default) |
| `require` | Always use SSL | None | Basic security |
| `verify-ca` | SSL + verify CA certificate | Yes | **Production** ⭐ |
| `verify-full` | SSL + verify CA + hostname | Yes | Maximum security |

### SSL Configuration

In your `values.yaml`:

```yaml
ssl:
  enabled: true
  mode: verify-ca
  secretName: citusdemo-ssl-certs
```

Or via command line:

```bash
helm install my-citus-cluster ./helm/citus-cluster \
  --set ssl.enabled=true \
  --set ssl.mode=verify-ca \
  --set ssl.secretName=my-ssl-certs
```

### SSL Certificate Secret Format

The secret must contain three files:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: citusdemo-ssl-certs
type: Opaque
data:
  ca.crt: <base64-encoded-ca-certificate>
  server.crt: <base64-encoded-server-certificate>
  server.key: <base64-encoded-server-private-key>
```

### Important SSL Notes

1. **Rebuild Docker image**: The Dockerfile must be rebuilt to support dynamic SSL configuration with environment variables
2. **Certificate SANs**: Certificates must include Subject Alternative Names (SANs) for Kubernetes DNS:
   - `*.${CLUSTER_NAME}.${NAMESPACE}.svc.cluster.local`
   - `*.${CLUSTER_NAME}-*.${NAMESPACE}.svc.cluster.local`
3. **Default mode**: By default, the cluster uses `PGSSLMODE=prefer` (SSL optional)
4. **Production**: Always use `verify-ca` or `verify-full` in production

### Troubleshooting SSL

If you encounter `SSL error: certificate verify failed`:

1. **Quick fix** (development): Set `ssl.mode=prefer` or `ssl.mode=require`
2. **Proper fix**: Ensure certificates have correct SANs:
   ```bash
   openssl x509 -in certs/server.crt -noout -ext subjectAltName
   ```
3. **Verify certificate chain**:
   ```bash
   openssl verify -CAfile certs/ca.crt certs/server.crt
   ```

For detailed SSL setup and troubleshooting, see [../../docs/SSL_SETUP.md](../../docs/SSL_SETUP.md).

## PostgreSQL Extensions Support

This chart includes support for automatically installing additional PostgreSQL extensions including PostGIS, pg_partman, and others. Extensions are pre-installed in the Docker image and can be automatically enabled on all cluster nodes.

### Available Extensions

The Docker image includes:
- **PostGIS** (`postgis`, `postgis_topology`) - Geospatial database capabilities
- **pg_partman** - Partition management for time-series and other data
  - **Note**: The pg_partman background worker (`pg_partman_bgw`) is pre-configured in `shared_preload_libraries`
  - This enables automated partition maintenance without manual intervention
  - Additional BGW settings can be configured via `postgresql.conf` (see [pg_partman documentation](https://github.com/pgpartman/pg_partman#setup))
- Any other PostgreSQL 16 compatible extensions available in Debian packages

### Enabling Extensions

To enable extensions automatically when deploying the cluster:

```yaml
additionalExtensions:
  enabled: true
  extensions:
    - postgis
    - postgis_topology
    - pg_partman
    # Add any other extensions here
```

Or via command line:

```bash
helm install my-citus-cluster ./helm/citus-cluster \
  --set additionalExtensions.enabled=true \
  --set additionalExtensions.extensions={postgis,postgis_topology,pg_partman}
```

### How It Works

When `additionalExtensions.enabled` is set to `true`:

1. A Kubernetes Job runs as a Helm post-install/post-upgrade hook
2. The job waits for the PostgreSQL cluster to be ready (configurable timeout)
3. Each extension is created on the coordinator using `CREATE EXTENSION IF NOT EXISTS ... CASCADE`
4. Citus automatically propagates extensions to all worker nodes
5. The job completes successfully or retries on failure

### pg_partman Background Worker Configuration

The pg_partman background worker is pre-configured in `shared_preload_libraries` for automated partition maintenance. To configure the BGW behavior, you can set additional PostgreSQL parameters:

```bash
# Connect to the coordinator
kubectl exec -it <clusterName>-0-0 -- psql -U postgres -d citus

# Configure BGW settings
ALTER DATABASE citus SET pg_partman_bgw.interval = 3600;  -- Run maintenance every hour
ALTER DATABASE citus SET pg_partman_bgw.role = 'postgres';  -- Role to run maintenance as
ALTER DATABASE citus SET pg_partman_bgw.dbname = 'citus';  -- Database to run maintenance on
```

These settings control:
- `pg_partman_bgw.interval` - How often maintenance runs (in seconds)
- `pg_partman_bgw.role` - Which database role executes the background worker
- `pg_partman_bgw.dbname` - Which database(s) receive automated partition maintenance

For more details, see the [pg_partman setup documentation](https://github.com/pgpartman/pg_partman#setup).

### Default Extensions

By default, the following extensions are configured (when enabled):
- `postgis` - Core PostGIS geospatial functionality
- `postgis_topology` - Topology support for PostGIS
- `pg_partman` - Table partition management

### Advanced Extension Configuration

Customize extension installation behavior with additional options:

```yaml
additionalExtensions:
  enabled: true
  # Maximum attempts to wait for PostgreSQL to be ready
  maxAttempts: 60
  # Delay between retry attempts (seconds)
  retryDelaySeconds: 5
  # Number of times to retry the job on failure
  backoffLimit: 3
  # [DEPRECATED] Enable on worker nodes - Citus automatically propagates extensions
  enableOnWorkers: false
  # Extensions to enable
  extensions:
    - postgis
    - postgis_topology
    - pg_partman
    # Add more extensions as needed
```

**Note**: The `enableOnWorkers` option is deprecated. When you create extensions on the Citus coordinator, they are automatically created on all worker nodes.

### Verifying Extension Installation

After deployment, verify extensions are working:

```bash
# Connect to the coordinator
kubectl exec -it <clusterName>-0-0 -- psql -U postgres -d citus

# Check PostGIS version (if enabled)
SELECT PostGIS_Version();

# Check pg_partman (if enabled)
SELECT partman.show_partitions('test_table');

# List all installed extensions
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE installed_version IS NOT NULL
ORDER BY name;

# Check which extensions are available
SELECT name, default_version, comment
FROM pg_available_extensions
WHERE name IN ('postgis', 'pg_partman', 'postgis_topology')
ORDER BY name;
```

### Adding Extensions to Existing Cluster

If you deployed the cluster without extensions and want to add them later:

```bash
# Update your values to enable extensions
helm upgrade my-citus-cluster ./helm/citus-cluster \
  --set additionalExtensions.enabled=true \
  --reuse-values
```

The extension setup job will run automatically as part of the upgrade.

### Manual Extension Installation

If you prefer to enable extensions manually:

```bash
# Connect to the coordinator
kubectl exec -it <clusterName>-0-0 -- psql -U postgres -d citus

# Create extensions (they auto-propagate to workers via Citus)
CREATE EXTENSION IF NOT EXISTS postgis CASCADE;
CREATE EXTENSION IF NOT EXISTS postgis_topology CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_partman CASCADE;
```

**Note**: When creating extensions on the Citus coordinator, there's no need to manually create them on worker nodes - Citus handles this automatically.

### Adding Custom Extensions

To add custom extensions not included in the Docker image:

1. **Modify the Dockerfile** to install your extension package:
   ```dockerfile
   ## Install PostGIS and pg_partman
   && apt-get install -y postgresql-16-postgis-3 postgresql-16-postgis-3-scripts \
   postgresql-16-partman \
   postgresql-16-your-extension \  # Add your extension
   ```

2. **Rebuild the Docker image**:
   ```bash
   docker build -f Dockerfile.citus -t your-registry/citus:custom .
   docker push your-registry/citus:custom
   ```

3. **Add to your values**:
   ```yaml
   image:
     repository: your-registry/citus
     tag: custom

   additionalExtensions:
     enabled: true
     extensions:
       - postgis
       - pg_partman
       - your_extension
   ```

4. **Deploy or upgrade**:
   ```bash
   helm upgrade --install my-citus-cluster ./helm/citus-cluster -f values.yaml
   ```

## Accessing the Cluster

After installation, you can access the coordinator:

```bash
# Get the coordinator service
kubectl get svc <clusterName>-0

# Connect to the coordinator
kubectl exec -it <clusterName>-0-0 -- psql -U postgres -d citus
```

## Uninstallation

```bash
helm uninstall my-citus-cluster
```

If using persistent volumes, you may need to manually delete the PVCs:

```bash
kubectl delete pvc -l cluster-name=<clusterName>
```

## Upgrading

```bash
helm upgrade my-citus-cluster ./helm/citus-cluster -f my-values.yaml
```

## Security Considerations

The default passwords in `values.yaml` are for demonstration purposes only. For production deployments, you have several options:

### Option 1: Let Helm Create a Secret with Strong Passwords

Update `values.yaml` or use `--set` flags:

```bash
helm install my-citus-cluster ./helm/citus-cluster \
  --set patroni.superuser.password=<strong-password> \
  --set patroni.replication.password=<strong-password>
```

### Option 2: Use an Existing Secret

If you already have a secret in your cluster:

```bash
# Create your secret first
kubectl create secret generic my-citus-secret \
  --from-literal=superuser-password=<strong-password> \
  --from-literal=replication-password=<strong-password>

# Install with existing secret
helm install my-citus-cluster ./helm/citus-cluster \
  --set secret.create=false \
  --set secret.name=my-citus-secret
```

Or in your `values.yaml`:

```yaml
secret:
  create: false
  name: my-citus-secret
  # Ensure your secret has these keys:
  keys:
    superuserPassword: superuser-password
    replicationPassword: replication-password
```

**Note:** If your existing secret uses different key names, update the `secret.keys` values accordingly:

```yaml
secret:
  create: false
  name: my-citus-secret
  keys:
    superuserPassword: postgres-password  # your custom key name
    replicationPassword: standby-password  # your custom key name
```

### Option 3: Use External Secret Management

Consider using external secret management solutions like:
- Sealed Secrets
- External Secrets Operator
- HashiCorp Vault

With these tools, set `secret.create: false` and manage the secret externally.

## Troubleshooting

### Pods Not Starting

Check pod status and events:

```bash
kubectl get pods -l cluster-name=<clusterName>
kubectl describe pod <pod-name>
kubectl logs <pod-name>
```

### Init Container Issues

If init containers are stuck:

```bash
# Check init container logs
kubectl logs <pod-name> -c fix-permissions

# The extension installation uses a Job, not init containers
# Check the job status:
kubectl get jobs -l job-type=extensions-setup
kubectl logs job/<clusterName>-extensions-setup
```

### SSL Certificate Errors

If you see `SSL error: certificate verify failed`:

```bash
# Check SSL environment variables
kubectl exec -it <pod-name> -- env | grep PGSSL

# Verify certificates are mounted
kubectl exec -it <pod-name> -- ls -la /etc/ssl/certs/postgresql/

# Check Patroni logs for SSL errors
kubectl logs <pod-name> | grep -i ssl

# Verify certificate validity
kubectl exec -it <pod-name> -- openssl verify -CAfile /etc/ssl/certs/postgresql/ca.crt /etc/ssl/certs/postgresql/server.crt
```

See [../../docs/SSL_SETUP.md](../../docs/SSL_SETUP.md#troubleshooting) for detailed SSL troubleshooting.

### Extension Setup Job Failed

If the extension setup job fails:

```bash
# Check job status
kubectl get jobs -l job-type=extensions-setup
kubectl describe job <clusterName>-extensions-setup

# Check job logs
kubectl logs job/<clusterName>-extensions-setup

# Manually enable extensions if needed
kubectl exec -it <clusterName>-0-0 -- psql -U postgres -d citus \
  -c "CREATE EXTENSION IF NOT EXISTS postgis CASCADE;"
kubectl exec -it <clusterName>-0-0 -- psql -U postgres -d citus \
  -c "CREATE EXTENSION IF NOT EXISTS pg_partman CASCADE;"
```

Common issues:
- **Cluster not ready**: The job waits for the cluster, but may timeout if there are startup issues
- **Extension not found**: Ensure the extension package is installed in the Docker image
- **Permission errors**: The job uses the superuser credentials from the secret

### Patroni Cluster Status

Check cluster health:

```bash
kubectl exec -it <clusterName>-0-0 -- patronictl list
```

### Connection Issues

Test database connectivity:

```bash
# Connect to coordinator
kubectl exec -it <clusterName>-0-0 -- psql -U postgres -d citus

# Check cluster nodes
kubectl exec -it <clusterName>-0-0 -- psql -U postgres -d citus -c "SELECT * FROM pg_dist_node;"

# Check SSL connections
kubectl exec -it <clusterName>-0-0 -- psql -U postgres -d citus -c "SELECT usename, client_addr, ssl, version FROM pg_stat_ssl JOIN pg_stat_activity USING (pid);"
```

## Production Best Practices

1. **Use Persistent Volumes**:
   ```yaml
   storage:
     persistentVolume:
       enabled: true
       storageClass: "fast-ssd"
       size: 100Gi
   ```

2. **Enable SSL with Certificate Verification**:
   ```yaml
   ssl:
     enabled: true
     mode: verify-ca
   ```

3. **Use Strong Passwords**:
   - Never use default passwords
   - Create secrets externally
   - Consider using secret management tools (Vault, Sealed Secrets)

4. **Configure Resource Limits**:
   ```yaml
   resources:
     limits:
       cpu: "4"
       memory: "8Gi"
     requests:
       cpu: "2"
       memory: "4Gi"
   ```

5. **Set Up Monitoring**:
   - Monitor Patroni health endpoints (`:8008/health`)
   - Track PostgreSQL metrics
   - Monitor certificate expiration dates

6. **Plan for Certificate Rotation**:
   - Certificates generated by the script are valid for 3 years
   - Set up automated rotation before expiry
   - Consider using cert-manager for automatic renewal

## Related Documentation

- [Main Repository README](../../README.md) - Overview and quick start
- [SSL/TLS Setup Guide](../../docs/SSL_SETUP.md) - Comprehensive SSL configuration
- [Citus Documentation](https://docs.citusdata.com/)
- [Patroni Documentation](https://patroni.readthedocs.io/)

## Support

For issues or questions:
1. Check the [Troubleshooting](#troubleshooting) section
2. Review pod and Patroni logs
3. Consult the [SSL Setup Guide](../../docs/SSL_SETUP.md) for SSL-related issues
4. Open an issue in the project repository

## License

This chart is based on the Patroni and Citus projects.
