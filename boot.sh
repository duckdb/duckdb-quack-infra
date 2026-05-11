#!/bin/bash
set -euo pipefail

export HOME="${HOME:-/root}"

# --- Gather instance context (IMDSv2) ---
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
IMDS="curl -s -H X-aws-ec2-metadata-token:${IMDS_TOKEN}"
MY_IP=$(${IMDS} http://169.254.169.254/latest/meta-data/public-ipv4)
MY_LOCAL_IP=$(${IMDS} http://169.254.169.254/latest/meta-data/local-ipv4)
MY_INSTANCE_ID=$(${IMDS} http://169.254.169.254/latest/meta-data/instance-id)
MY_INSTANCE_TYPE=$(${IMDS} http://169.254.169.254/latest/meta-data/instance-type)
MY_REGION=$(${IMDS} http://169.254.169.254/latest/meta-data/placement/region)
MY_HOSTNAME="${MY_IP}.nip.io"

# --- Install duckdb + quack (skipped when already baked into AMI) ---
DUCKDB_VERSION="${DUCKDB_VERSION:-1.5.2}"
DUCKDB=~/.duckdb/cli/${DUCKDB_VERSION}/duckdb
if [ ! -x "${DUCKDB}" ]; then
    curl -fsSL https://install.duckdb.org | HOME_DIR=~ DUCKDB_VERSION=${DUCKDB_VERSION} sh
fi

${DUCKDB} -c "FORCE INSTALL quack FROM core_nightly;"

# --- Write clean nginx config ---
cat > /etc/nginx/sites-enabled/default <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${MY_HOSTNAME};
    root /var/www/html;

    location /quack {
        proxy_pass http://127.0.0.1:1294;
        proxy_http_version 1.1;
        proxy_set_header Connection "keep-alive";
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
NGINX
nginx -t && systemctl reload nginx

# --- Get TLS cert (certbot adds SSL server block) ---
certbot --nginx --non-interactive --agree-tos \
    -m noreply@example.com \
    -d "${MY_HOSTNAME}"

# --- Generate boot context SQL ---
cat > /tmp/boot_context.sql <<SQL
LOAD quack;
SET VARIABLE my_ip = '${MY_IP}';
SET VARIABLE my_local_ip = '${MY_LOCAL_IP}';
SET VARIABLE my_hostname = '${MY_HOSTNAME}';
SET VARIABLE my_instance_id = '${MY_INSTANCE_ID}';
SET VARIABLE my_instance_type = '${MY_INSTANCE_TYPE}';
SET VARIABLE my_region = '${MY_REGION}';
SQL

# --- Read user-data as SQL (if any) ---
USER_SQL=$(${IMDS} -w "%{http_code}" -o /tmp/user_data_raw http://169.254.169.254/latest/user-data || echo "404")
if [ "${USER_SQL}" = "200" ]; then
    cp /tmp/user_data_raw /tmp/user_init.sql
else
    echo "CALL quack_serve('quack:0.0.0.0:1294', allow_other_hostname=true);" > /tmp/user_init.sql
fi

# --- Start duckdb with boot context + user SQL ---
cat /tmp/boot_context.sql /tmp/user_init.sql > /tmp/init.sql
sleep infinity | ${DUCKDB} -init /tmp/init.sql &

echo "Ready at https://${MY_HOSTNAME}/quack"
