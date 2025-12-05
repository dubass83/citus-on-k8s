# SSL/TLS Configuration for Citus on Kubernetes

This guide explains how to configure SSL/TLS encryption for your Citus PostgreSQL cluster running on Kubernetes.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [SSL Modes](#ssl-modes)
- [Certificate Generation](#certificate-generation)
- [Deployment](#deployment)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Production Considerations](#production-considerations)

## Overview

The Citus cluster supports SSL/TLS encryption for:
- Client-to-PostgreSQL connections
- PostgreSQL replication between coordinator and workers
- Patroni internal communications
- Citus distributed query communications

By default, the cluster runs with `PGSSLMODE=prefer`, which attempts SSL but falls back to unencrypted connections if SSL fails. For production environments, we recommend using `verify-ca` or `verify-full` modes.

## Quick Start

### 1. Generate SSL Certificates

Use the provided script to generate a Certificate Authority (CA) and server certificates:

```bash
cd /path/to/citus-on-k8s
export CLUSTER_NAME=citusdemo
export NAMESPACE=default

# Generate certificates
./scripts/generate-ssl-certs.sh
```

This creates certificates in the `certs/` directory:
- `ca.crt` - CA certificate (public)
- `ca.key` - CA private key (keep secure!)
- `server.crt` - Server certificate (public)
- `server.key` - Server private key (keep secure!)

### 2. Create Kubernetes Secret

Create a Kubernetes secret with the generated certificates:

```bash
kubectl create secret generic citusdemo-ssl-certs \
  --from-file=ca.crt=certs/ca.crt \
  --from-file=server.crt=certs/server.crt \
  --from-file=server.key=certs/server.key \
  --namespace=default
```

### 3. Enable SSL in Helm Values

Update your `values.yaml` or create a custom values file:

```yaml
ssl:
  enabled: true
  mode: verify-ca  # or verify-full for hostname verification
  secretName: citusdemo-ssl-certs
```

### 4. Deploy or Upgrade

```bash
helm upgrade --install citusdemo ./helm/citus-cluster \
  --namespace default \
  --values your-custom-values.yaml
```

## SSL Modes

PostgreSQL supports several SSL modes. Choose based on your security requirements:

| Mode | Description | Certificate Validation | Use Case |
|------|-------------|------------------------|----------|
| `disable` | No SSL | None | Development only |
| `allow` | Try unencrypted first, then SSL | None | Not recommended |
| `prefer` | Try SSL first, fall back to unencrypted | None | Default, backwards compatible |
| `require` | Always use SSL | None | Basic encryption |
| `verify-ca` | Always use SSL, verify CA | Yes | **Recommended for production** |
| `verify-full` | Always use SSL, verify CA + hostname | Yes | Maximum security |

### Recommended Settings

**Development/Testing:**
```yaml
ssl:
  enabled: false  # or use prefer mode
  mode: prefer
```

**Production:**
```yaml
ssl:
  enabled: true
  mode: verify-ca  # or verify-full
  secretName: your-cluster-ssl-certs
```

## Certificate Generation

### Automatic Generation (Recommended)

Use the provided script:

```bash
export CLUSTER_NAME=citusdemo
export NAMESPACE=default
./scripts/generate-ssl-certs.sh
```

The script generates:
1. **CA Certificate** (10-year validity)
   - Used to sign server certificates
   - Must be trusted by all clients and servers

2. **Server Certificate** (3-year validity)
   - Includes Subject Alternative Names (SANs) for Kubernetes DNS
   - Valid for all pods in the cluster

### Manual Generation

If you prefer to generate certificates manually:

```bash
# 1. Generate CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/CN=Citus-CA/O=YourOrg/C=US"

# 2. Generate server key
openssl genrsa -out server.key 2048

# 3. Create server certificate request
cat > server.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = *.citusdemo.default.svc.cluster.local
O = YourOrg
C = US

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.citusdemo.default.svc.cluster.local
DNS.2 = *.citusdemo-*.default.svc.cluster.local
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF

openssl req -new -key server.key -out server.csr -config server.cnf

# 4. Sign server certificate
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 1095 \
  -extensions v3_req -extfile server.cnf

# 5. Verify
openssl verify -CAfile ca.crt server.crt
```

### Using External CA (Production)

For production environments, you may want to use certificates from an external CA or cert-manager:

```bash
# If using cert-manager, create a Certificate resource
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: citusdemo-ssl
  namespace: default
spec:
  secretName: citusdemo-ssl-certs
  duration: 2160h # 90 days
  renewBefore: 360h # 15 days
  subject:
    organizations:
      - YourOrg
  commonName: "*.citusdemo.default.svc.cluster.local"
  dnsNames:
    - "*.citusdemo.default.svc.cluster.local"
    - "*.citusdemo-*.default.svc.cluster.local"
  issuerRef:
    name: your-issuer
    kind: ClusterIssuer
EOF
```

## Deployment

### Initial Deployment with SSL

```bash
# 1. Generate certificates
export CLUSTER_NAME=citusdemo
export NAMESPACE=default
./scripts/generate-ssl-certs.sh

# 2. Create secret
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

### Upgrading Existing Cluster to Use SSL

**Important:** This requires rebuilding the Docker image first to support dynamic SSL configuration.

```bash
# 1. Rebuild the Docker image with SSL support
docker build -f Dockerfile.citus -t patroni-citus-k8s:latest .

# 2. Push to your registry if needed
docker tag patroni-citus-k8s:latest your-registry/patroni-citus-k8s:latest
docker push your-registry/patroni-citus-k8s:latest

# 3. Generate certificates
export CLUSTER_NAME=citusdemo
export NAMESPACE=default
./scripts/generate-ssl-certs.sh

# 4. Create secret
kubectl create secret generic citusdemo-ssl-certs \
  --from-file=ca.crt=certs/ca.crt \
  --from-file=server.crt=certs/server.crt \
  --from-file=server.key=certs/server.key \
  --namespace=default

# 5. Upgrade Helm release
helm upgrade citusdemo ./helm/citus-cluster \
  --namespace default \
  --set ssl.enabled=true \
  --set ssl.mode=verify-ca \
  --set image.tag=latest

# 6. Rolling restart (if needed)
kubectl rollout restart statefulset citusdemo-0 -n default
kubectl rollout restart statefulset citusdemo-1 -n default
```

## Verification

### 1. Check Pod Environment Variables

```bash
kubectl exec -it citusdemo-0-0 -n default -- env | grep PGSSL
```

Expected output:
```
PGSSLMODE=verify-ca
PGSSLROOTCERT=/etc/ssl/certs/postgresql/ca.crt
PGSSLCERT=/etc/ssl/certs/postgresql/server.crt
PGSSLKEY=/etc/ssl/certs/postgresql/server.key
```

### 2. Verify Certificates are Mounted

```bash
kubectl exec -it citusdemo-0-0 -n default -- ls -la /etc/ssl/certs/postgresql/
```

Expected output:
```
-rw------- 1 postgres postgres 1234 ... ca.crt
-rw------- 1 postgres postgres 5678 ... server.crt
-rw------- 1 postgres postgres 1704 ... server.key
```

### 3. Test SSL Connection

From inside a pod:

```bash
kubectl exec -it citusdemo-0-0 -n default -- bash

# Test connection with SSL
psql "sslmode=verify-ca sslrootcert=/etc/ssl/certs/postgresql/ca.crt host=citusdemo-0 user=postgres dbname=citus"

# Check if SSL is active
psql -h citusdemo-0 -U postgres -d citus -c "SELECT ssl.pid, ssl.version, ssl.cipher FROM pg_stat_ssl ssl JOIN pg_stat_activity act ON ssl.pid = act.pid WHERE act.usename = 'postgres';"
```

### 4. Check Patroni Logs

```bash
kubectl logs citusdemo-0-0 -n default | grep -i ssl
```

Look for:
- No SSL errors
- Successful SSL connections
- No certificate verification failures

### 5. Verify Replication SSL

```bash
kubectl exec -it citusdemo-0-0 -n default -- \
  psql -U postgres -d citus -c "SELECT client_addr, state, sync_state, ssl FROM pg_stat_replication;"
```

The `ssl` column should show `t` (true).

## Troubleshooting

### Issue: Certificate Verify Failed

**Symptoms:**
```
SSL error: certificate verify failed
psycopg2.OperationalError: connection to server failed: SSL error
```

**Solutions:**

1. **Check certificate validity:**
   ```bash
   openssl x509 -in certs/server.crt -noout -dates
   ```

2. **Verify Subject Alternative Names include correct DNS:**
   ```bash
   openssl x509 -in certs/server.crt -noout -ext subjectAltName
   ```

3. **Ensure secret is correctly created:**
   ```bash
   kubectl get secret citusdemo-ssl-certs -n default -o yaml
   ```

4. **Check certificate chain:**
   ```bash
   openssl verify -CAfile certs/ca.crt certs/server.crt
   ```

### Issue: Permission Denied on Certificate Files

**Symptoms:**
```
could not access private key file: Permission denied
```

**Solution:**

The secret should be mounted with mode 0600. Check StatefulSet:
```bash
kubectl get statefulset citusdemo-0 -n default -o yaml | grep -A5 defaultMode
```

Should show:
```yaml
defaultMode: 384  # 0600 in octal
```

### Issue: Pods Not Starting After Enabling SSL

**Symptoms:**
Pods stuck in `CrashLoopBackOff`

**Solutions:**

1. **Check if secret exists:**
   ```bash
   kubectl get secret citusdemo-ssl-certs -n default
   ```

2. **Temporarily disable SSL to recover:**
   ```bash
   helm upgrade citusdemo ./helm/citus-cluster \
     --namespace default \
     --set ssl.enabled=false
   ```

3. **Check pod events:**
   ```bash
   kubectl describe pod citusdemo-0-0 -n default
   ```

### Issue: Mixed SSL and Non-SSL Connections

**Symptoms:**
Some connections work, others fail with SSL errors

**Solution:**

Ensure all environment variables are set correctly. Check that the Docker image was rebuilt with the dynamic SSL configuration changes.

## Production Considerations

### Certificate Rotation

Plan for certificate rotation before expiry:

1. **Monitor certificate expiration:**
   ```bash
   openssl x509 -in certs/server.crt -noout -enddate
   ```

2. **Rotate certificates:**
   ```bash
   # Generate new certificates
   ./scripts/generate-ssl-certs.sh
   
   # Update secret
   kubectl create secret generic citusdemo-ssl-certs \
     --from-file=ca.crt=certs/ca.crt \
     --from-file=server.crt=certs/server.crt \
     --from-file=server.key=certs/server.key \
     --namespace=default \
     --dry-run=client -o yaml | kubectl apply -f -
   
   # Rolling restart
   kubectl rollout restart statefulset citusdemo-0 -n default
   ```

3. **Use cert-manager for automatic rotation:**
   Install cert-manager and use Certificate resources for automated renewal.

### Security Best Practices

1. **Use `verify-full` mode when possible:**
   ```yaml
   ssl:
     mode: verify-full
   ```

2. **Keep private keys secure:**
   - Never commit `*.key` files to git
   - Use proper RBAC to restrict secret access
   - Consider using external secret management (Vault, AWS Secrets Manager)

3. **Use strong ciphers:**
   The current configuration uses TLS 1.2+ by default. PostgreSQL automatically negotiates the strongest available cipher.

4. **Regular certificate rotation:**
   - Rotate certificates every 90 days
   - Use shorter validity periods (90 days) for better security
   - Automate rotation with cert-manager

5. **Audit SSL connections:**
   ```sql
   -- Check which connections use SSL
   SELECT usename, client_addr, ssl, version 
   FROM pg_stat_ssl 
   JOIN pg_stat_activity USING (pid);
   ```

### Backup and Disaster Recovery

1. **Backup CA private key securely:**
   ```bash
   # Encrypt and store safely
   gpg --symmetric --cipher-algo AES256 certs/ca.key
   ```

2. **Store certificate copies in secret management:**
   - Use Kubernetes external secrets operator
   - Store in HashiCorp Vault
   - Use cloud provider secret managers (AWS Secrets Manager, GCP Secret Manager)

3. **Document certificate generation process:**
   Keep runbooks for regenerating certificates if CA key is lost.

### Monitoring

Set up monitoring for SSL-related metrics:

```sql
-- Create monitoring view
CREATE OR REPLACE VIEW ssl_connections AS
SELECT 
  usename,
  client_addr,
  ssl,
  version as ssl_version,
  cipher,
  bits
FROM pg_stat_ssl 
JOIN pg_stat_activity USING (pid)
WHERE ssl = true;
```

Monitor:
- Certificate expiration dates
- Failed SSL connection attempts
- Weak cipher usage
- Non-SSL connections (when `require` mode is set)

## Additional Resources

- [PostgreSQL SSL Documentation](https://www.postgresql.org/docs/current/ssl-tcp.html)
- [OpenSSL Documentation](https://www.openssl.org/docs/)
- [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Patroni SSL Configuration](https://patroni.readthedocs.io/en/latest/SETTINGS.html#postgresql)

## Support

For issues or questions:
1. Check the [Troubleshooting](#troubleshooting) section
2. Review pod logs: `kubectl logs <pod-name>`
3. Check Patroni status: `kubectl exec <pod-name> -- patronictl list`
4. Open an issue in the project repository
