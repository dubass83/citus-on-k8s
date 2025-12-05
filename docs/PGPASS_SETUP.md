# .pgpass Configuration for Citus Worker Authentication

This document explains how to configure `.pgpass` file for Citus worker authentication using ConfigMap-based mounting.

## Overview

When using password-based authentication (instead of certificate-based), Citus coordinators need to authenticate to worker nodes when calling `citus_add_node()`. The `.pgpass` file provides a secure way to store these credentials without embedding passwords in SQL commands.

## When to Use .pgpass

Use `.pgpass` configuration when:
- You're using password-based authentication (`md5` or `scram-sha-256` in `pg_hba.conf`)
- You need to register workers from coordinator using `citus_add_node()`
- You want to avoid manual password entry for inter-node connections

**Note**: If you're using certificate-based authentication (recommended for production), you don't need `.pgpass`. See [CERTIFICATE_AUTHENTICATION.md](CERTIFICATE_AUTHENTICATION.md) instead.

## Architecture

### How It Works

1. **ConfigMap Creation**: Helm template generates a ConfigMap with `.pgpass` entries
2. **Init Container**: Substitutes `${POSTGRES_PASSWORD}` placeholder with actual password from Secret
3. **Mount**: Copies the processed `.pgpass` file to `/home/postgres/.pgpass` with `0600` permissions
4. **Usage**: PostgreSQL automatically uses `.pgpass` for authentication when connecting to workers

### Components

- **ConfigMap**: `<cluster-name>-pgpass` - Contains `.pgpass` template with password placeholders
- **Init Container**: `fix-permissions` - Processes template and sets up `.pgpass` file
- **Volumes**:
  - `pgpass-template` - ConfigMap volume (read-only)
  - `pgpass-config` - EmptyDir for processed file

## Configuration

### Enable .pgpass in values.yaml

```yaml
pgpass:
  enabled: true
  
  # Optional: Custom entries (in addition to auto-generated worker entries)
  entries:
    - host: "external-postgres.example.com"
      port: 5432
      database: "*"
      username: "postgres"
```

### Generated .pgpass Format

The ConfigMap automatically includes entries for all worker service names:

```
# Auto-generated entries for worker services
citusstage-1:5432:*:postgres:${POSTGRES_PASSWORD}
citusstage-2:5432:*:postgres:${POSTGRES_PASSWORD}
```

The `${POSTGRES_PASSWORD}` placeholder is replaced at runtime with the actual password from the Kubernetes Secret.

### File Permissions

The init container ensures:
- `.pgpass` is owned by user `999:999` (postgres user)
- Permissions are set to `0600` (required by PostgreSQL)
- File is readable only by the postgres user

## Deployment

### Step 1: Update values.yaml

Edit your values file (e.g., `values.stg.yaml`):

```yaml
pgpass:
  enabled: true
```

### Step 2: Deploy with Helm

```bash
# Upgrade existing deployment
helm upgrade citusstage ./helm/citus-cluster \
  -f helm/citus-cluster/values.stg.yaml \
  -n citus-cluster-stage

# Or install new deployment
helm install citusstage ./helm/citus-cluster \
  -f helm/citus-cluster/values.stg.yaml \
  -n citus-cluster-stage
```

### Step 3: Verify .pgpass is Mounted

```bash
# Check .pgpass file exists and has correct permissions
kubectl exec -it citusstage-0-0 -n citus-cluster-stage -- ls -la /home/postgres/.pgpass

# Expected output:
# -rw------- 1 postgres postgres 123 Jan 28 10:00 /home/postgres/.pgpass

# View .pgpass content (be careful with password exposure!)
kubectl exec -it citusstage-0-0 -n citus-cluster-stage -- cat /home/postgres/.pgpass
```

### Step 4: Test Worker Connection

```bash
# Test connection to worker (should not prompt for password)
kubectl exec -it citusstage-0-0 -n citus-cluster-stage -- \
  psql -h citusstage-1 -U postgres -d postgres -c "SELECT version();"

# If successful, you should see PostgreSQL version without password prompt
```

### Step 5: Register Workers

```bash
# Connect to skymap database
kubectl exec -it citusstage-0-0 -n citus-cluster-stage -- \
  psql -U postgres -d skymap
```

```sql
-- Add workers using service names
SELECT * FROM citus_add_node('citusstage-1', 5432);

-- Verify workers are registered
SELECT nodename, nodeport, noderole, groupid 
FROM pg_dist_node 
WHERE noderole = 'primary' AND groupid > 0;

-- Test distributed query
SELECT run_command_on_workers('SELECT version()');
```

## Troubleshooting

### .pgpass File Not Found

**Symptom**: `psql` still prompts for password

**Solutions**:
1. Check if pgpass is enabled: `helm get values citusstage -n citus-cluster-stage | grep -A3 pgpass`
2. Verify ConfigMap exists: `kubectl get configmap citusstage-pgpass -n citus-cluster-stage`
3. Check pod has the volume mount: `kubectl describe pod citusstage-0-0 -n citus-cluster-stage | grep pgpass`

### Permission Denied

**Symptom**: `WARNING: password file "/home/postgres/.pgpass" has group or world access; permissions should be u=rw (0600) or less`

**Solutions**:
1. Check file permissions: `kubectl exec -it citusstage-0-0 -n citus-cluster-stage -- stat /home/postgres/.pgpass`
2. Should show: `Access: (0600/-rw-------)  Uid: (  999/ postgres)   Gid: (  999/ postgres)`
3. If incorrect, restart pod: `kubectl delete pod citusstage-0-0 -n citus-cluster-stage`

### Password Not Substituted

**Symptom**: `.pgpass` file contains literal `${POSTGRES_PASSWORD}` instead of actual password

**Solutions**:
1. Check Secret exists: `kubectl get secret citus-secrets -n citus-cluster-stage`
2. Verify Secret key: `kubectl get secret citus-secrets -n citus-cluster-stage -o jsonpath='{.data.superuser-password}' | base64 -d`
3. Check init container logs: `kubectl logs citusstage-0-0 -n citus-cluster-stage -c fix-permissions`

### Connection Still Fails

**Symptom**: `fe_sendauth: no password supplied` even with `.pgpass` configured

**Possible causes**:
1. **Hostname mismatch**: Ensure you're using service names (`citusstage-1`) not IPs
2. **Port mismatch**: Verify port in `.pgpass` matches actual port (default: 5432)
3. **Username mismatch**: Ensure username in `.pgpass` matches connection attempt
4. **Database mismatch**: Use `*` for database in `.pgpass` to match all databases
5. **pg_hba.conf**: Verify worker nodes accept password authentication

**Debug**:
```bash
# Check pg_hba.conf on worker
kubectl exec -it citusstage-1-0 -n citus-cluster-stage -- \
  cat /home/postgres/pgdata/pgroot/data/pg_hba.conf

# Should include:
# hostssl all postgres 10.110.0.0/16 md5
# or
# hostssl all all all md5
```

## Security Considerations

### Password Exposure

- `.pgpass` file contains plaintext passwords
- File permissions (0600) restrict access to postgres user only
- ConfigMap is stored in etcd (encrypted at rest if configured)
- Never commit `.pgpass` content to git repositories

### Best Practices

1. **Use certificate-based authentication** in production (see [CERTIFICATE_AUTHENTICATION.md](CERTIFICATE_AUTHENTICATION.md))
2. **Rotate passwords regularly** by updating the Secret and restarting pods
3. **Limit .pgpass entries** to only required hosts
4. **Use service names** instead of IP addresses for better SSL/TLS support
5. **Monitor access** to the ConfigMap and Secret

## Alternative: Certificate-Based Authentication

For production environments, consider using certificate-based authentication instead:

**Advantages**:
- No passwords stored in configuration
- Better security posture
- No need for `.pgpass` file
- Automatic mutual TLS

**See**: [CERTIFICATE_AUTHENTICATION.md](CERTIFICATE_AUTHENTICATION.md) for implementation guide.

## Comparison: .pgpass vs Certificate Auth

| Feature | .pgpass | Certificate Auth |
|---------|---------|------------------|
| Security | Medium (password-based) | High (PKI-based) |
| Setup Complexity | Low | Medium |
| Password Rotation | Required | Not needed |
| SSL/TLS Integration | Optional | Built-in |
| Production Ready | Yes (with SSL) | Yes (recommended) |
| Kubernetes Native | Yes (ConfigMap) | Yes (Secret) |

## See Also

- [CERTIFICATE_AUTHENTICATION.md](CERTIFICATE_AUTHENTICATION.md) - Certificate-based auth setup
- [DATABASE_MANAGEMENT.md](DATABASE_MANAGEMENT.md) - Creating additional databases
- [SSL_SETUP.md](SSL_SETUP.md) - SSL/TLS configuration
- [DATABASE_MANAGEMENT_TROUBLESHOOTING.md](DATABASE_MANAGEMENT_TROUBLESHOOTING.md) - Common issues
