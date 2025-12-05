#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/../certs"
NAMESPACE="${NAMESPACE:-default}"
CLUSTER_NAME="${CLUSTER_NAME:-citusdemo}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Generating SSL certificates for Citus cluster${NC}"
echo "Cluster Name: ${CLUSTER_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Certificates directory: ${CERTS_DIR}"
echo ""

mkdir -p "${CERTS_DIR}"
cd "${CERTS_DIR}"
rm -f ca.key ca.crt server.key server.crt server.csr

echo -e "${YELLOW}Step 1: Generating CA (Certificate Authority)${NC}"
openssl genrsa -out ca.key 4096

# Create CA config to enable extensions signing
cat > ca.cnf <<EOF
[ca]
default_ca = CA_default

[CA_default]
copy_extensions = copy
EOF

openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/CN=Citus-CA/O=Citus/C=US"

echo -e "${GREEN}✓ CA certificate generated${NC}"
echo ""

echo -e "${YELLOW}Step 2: Generating server/client certificate${NC}"
openssl genrsa -out server.key 2048

# Updated config with proper key usage for BOTH server and client auth
cat > server.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = *.${CLUSTER_NAME}.${NAMESPACE}.svc.cluster.local
O = Citus
C = US

[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment, keyAgreement
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[v3_ca]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment, keyAgreement
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.${CLUSTER_NAME}.${NAMESPACE}.svc.cluster.local
DNS.2 = *.${CLUSTER_NAME}-*.${NAMESPACE}.svc.cluster.local
DNS.3 = *.${CLUSTER_NAME}-*.${NAMESPACE}.svc
DNS.4 = *.${NAMESPACE}.svc.cluster.local
DNS.5 = localhost
DNS.6 = *.cluster.local
IP.1 = 127.0.0.1
EOF

openssl req -new -key server.key -out server.csr -config server.cnf

# CRITICAL: Use -extensions v3_ca to ensure extensions are included in final cert
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 1095 \
  -extensions v3_ca -extfile server.cnf

echo -e "${GREEN}✓ Server certificate generated${NC}"
echo ""

chmod 600 server.key ca.key
chmod 644 server.crt ca.crt

echo -e "${YELLOW}Step 3: Verifying certificates${NC}"
openssl verify -CAfile ca.crt server.crt

echo -e "${YELLOW}Step 4: Detailed certificate inspection${NC}"
echo "Checking extendedKeyUsage in certificate:"
openssl x509 -in server.crt -noout -text | grep -A 1 "Extended Key Usage"
echo ""
echo "Full certificate details:"
openssl x509 -in server.crt -noout -subject -dates -ext subjectAltName,keyUsage,extendedKeyUsage
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}SSL Certificates generated successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Generated files:"
echo "  - ca.crt       (CA certificate)"
echo "  - ca.key       (CA private key)"
echo "  - server.crt   (Server certificate with clientAuth)"
echo "  - server.key   (Server private key)"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Create Kubernetes secret:"
echo "   kubectl create secret generic ${CLUSTER_NAME}-ssl-certs \\"
echo "     --from-file=ca.crt=ca.crt \\"
echo "     --from-file=server.crt=server.crt \\"
echo "     --from-file=server.key=server.key \\"
echo "     --namespace=${NAMESPACE}"
echo ""
echo "2. Verify PostgreSQL SSL configuration includes:"
echo "   ssl_ca_file = '/path/to/ca.crt'"
echo "   ssl_cert_file = '/path/to/server.crt'"
echo "   ssl_key_file = '/path/to/server.key'"
echo ""
echo "3. Check pg_hba.conf allows SSL connections:"
echo "   hostssl all all all cert clientcert=verify-ca"
echo ""
echo -e "${RED}IMPORTANT: Keep ca.key and server.key secure!${NC}"