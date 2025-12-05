#!/bin/bash

if [[ $UID -ge 10000 ]]; then
    GID=$(id -g)
    sed -e "s/^postgres:x:[^:]*:[^:]*:/postgres:x:$UID:$GID:/" /etc/passwd > /tmp/passwd
    cat /tmp/passwd > /etc/passwd
    rm /tmp/passwd
fi

# Determine authentication method based on SSL mode
# If using certificate-based SSL (verify-ca or verify-full), enable cert auth for postgres user
if [[ "${PGSSLMODE}" == "verify-ca" || "${PGSSLMODE}" == "verify-full" ]]; then
    PG_HBA_POSTGRES_AUTH="cert clientcert=verify-full map=cnmap"
    PG_HBA_OTHER_AUTH="md5"
    PG_HBA_REPL_AUTH="md5"
    NEED_PG_IDENT="true"
else
    # For other SSL modes (disable, allow, prefer, require), use password-based auth
    PG_HBA_POSTGRES_AUTH="md5"
    PG_HBA_OTHER_AUTH="md5"
    PG_HBA_REPL_AUTH="md5"
    NEED_PG_IDENT="false"
fi

cat > /home/postgres/patroni.yml <<__EOF__
bootstrap:
  dcs:
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: ${PATRONI_POSTGRESQL_MAX_CONNECTIONS:-200}
        max_locks_per_transaction: ${PATRONI_POSTGRESQL_MAX_LOCKS_PER_TRANSACTION:-512}
        shared_buffers: ${PATRONI_POSTGRESQL_SHARED_BUFFERS:-16MB}
        shared_preload_libraries: ${PATRONI_POSTGRESQL_SHARED_PRELOAD_LIBRARIES:-'pg_partman_bgw'}
        work_mem: ${PATRONI_POSTGRESQL_WORK_MEM:-4MB}
        maintenance_work_mem: ${PATRONI_POSTGRESQL_MAINTENANCE_WORK_MEM:-64MB}
        effective_cache_size: ${PATRONI_POSTGRESQL_EFFECTIVE_CACHE_SIZE:-128MB}
        wal_buffers: ${PATRONI_POSTGRESQL_WAL_BUFFERS:-16MB}
        checkpoint_completion_target: ${PATRONI_POSTGRESQL_CHECKPOINT_COMPLETION_TARGET:-0.9}
        random_page_cost: ${PATRONI_POSTGRESQL_RANDOM_PAGE_COST:-1.1}
        ssl: ${PATRONI_POSTGRESQL_SSL:-'on'}
        ssl_ca_file: ${PGSSLROOTCERT}
        ssl_cert_file: ${PGSSLCERT}
        ssl_key_file: ${PGSSLKEY}
        citus.node_conninfo: 'sslrootcert=${PGSSLROOTCERT} sslkey=${PGSSLKEY} sslcert=${PGSSLCERT} sslmode=${PGSSLMODE}'
      pg_hba:
      - local all all trust
      # Allow non-SSL connections from localhost (for monitoring/health checks within pod)
      - host all all 127.0.0.1/32 md5
      - host all all ::1/128 md5
      # Dynamic authentication for postgres user (cert-based when PGSSLMODE is verify-ca/verify-full)
      - hostssl all ${PATRONI_SUPERUSER_USERNAME} 0.0.0.0/0 ${PG_HBA_POSTGRES_AUTH}
      # Authentication for other users
      - hostssl all all 0.0.0.0/0 ${PG_HBA_OTHER_AUTH}
      # Replication authentication
      - hostssl replication ${PATRONI_REPLICATION_USERNAME} ${PATRONI_KUBERNETES_POD_IP}/16 ${PG_HBA_REPL_AUTH}
      - hostssl replication ${PATRONI_REPLICATION_USERNAME} 127.0.0.1/32 ${PG_HBA_REPL_AUTH}
__EOF__

# Add pg_ident mapping only when using certificate authentication
if [[ "${NEED_PG_IDENT}" == "true" ]]; then
cat >> /home/postgres/patroni.yml <<__EOF__
      pg_ident:
      # Map any certificate CN to postgres user for certificate-based authentication
      - cnmap /^.*$ ${PATRONI_SUPERUSER_USERNAME}
__EOF__
fi

cat >> /home/postgres/patroni.yml <<__EOF__
  initdb:
  - auth-host: md5
  - auth-local: trust
  - encoding: UTF8
  - locale: en_US.UTF-8
  - data-checksums
restapi:
  connect_address: '${PATRONI_KUBERNETES_POD_IP}:8008'
postgresql:
  # Use hostname instead of IP for SSL certificate validation
  # Format: <pod-name>.<headless-service>.<namespace>.svc.cluster.local
  # The headless service is <scope>-<citus-group>-config (e.g., citusstage-0-config)
  connect_address: '${PATRONI_NAME}.${PATRONI_SCOPE}-${PATRONI_CITUS_GROUP}-config.${PATRONI_KUBERNETES_NAMESPACE}.svc.cluster.local:5432'
  authentication:
    superuser:
      password: '${PATRONI_SUPERUSER_PASSWORD}'
      sslmode: ${PGSSLMODE}
      sslkey: ${PGSSLKEY}
      sslcert: ${PGSSLCERT}
      sslrootcert: ${PGSSLROOTCERT}
    replication:
      password: '${PATRONI_REPLICATION_PASSWORD}'
      sslmode: ${PGSSLMODE}
      sslkey: ${PGSSLKEY}
      sslcert: ${PGSSLCERT}
      sslrootcert: ${PGSSLROOTCERT}
__EOF__

unset PATRONI_SUPERUSER_PASSWORD PATRONI_REPLICATION_PASSWORD


exec /usr/bin/python3 /usr/local/bin/patroni /home/postgres/patroni.yml
