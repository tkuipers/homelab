#!/bin/bash
#
# Create/update the read-only 'grafana_ro' database users that Grafana's
# Postgres/MySQL datasources log in with. Idempotent: run it after a fresh
# database, or after the passwords changed in 1Password
# (setup-observability-credentials.sh --rotate ... finalize runs it).
#
# Passwords come from the Secret observability/grafana-datasources (ExternalSecret
# -> 1Password item "Observability Credentials"). SQL goes over stdin so the
# passwords never show up in process arguments.
#
#   stocks          Postgres  stocks/postgres          db stocks
#   polymarket      Postgres  polymarket-bot/postgres  db polymarket_bot
#   stockguesser    MySQL     stock-guesser/mysql      db stocker
#
# grafana_ro: SELECT only (pg_read_all_data / GRANT SELECT), read-only
# transactions, 30s statement timeout, max 5 connections.

set -euo pipefail

kc() {
    if [ -f "${KUBECONFIG:-}" ]; then kubectl --kubeconfig="$KUBECONFIG" "$@"; else kubectl "$@"; fi
}

password() {
    kc -n observability get secret grafana-datasources -o jsonpath="{.data.$1}" | base64 -d
}

postgres_ro() {
    local ns="$1" key="$2" pw
    pw="$(password "$key")"
    [ -n "$pw" ] || { echo "no $key in observability/grafana-datasources" >&2; exit 1; }
    # $POSTGRES_USER is the superuser created by the postgres image
    kc -n "$ns" exec -i deploy/postgres -c postgres -- \
        sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafana_ro') THEN
    CREATE ROLE grafana_ro LOGIN;
  END IF;
END \$\$;
ALTER ROLE grafana_ro WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 5 PASSWORD '$pw';
ALTER ROLE grafana_ro SET default_transaction_read_only = on;
ALTER ROLE grafana_ro SET statement_timeout = '30s';
GRANT pg_read_all_data TO grafana_ro;
DO \$\$ BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO grafana_ro', current_database());
END \$\$;
SQL
    echo "postgres $ns: grafana_ro ok"
}

mysql_ro() {
    local ns="$1" db="$2" key="$3" pw
    pw="$(password "$key")"
    [ -n "$pw" ] || { echo "no $key in observability/grafana-datasources" >&2; exit 1; }
    kc -n "$ns" exec -i deploy/mysql -- \
        sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' <<SQL
CREATE USER IF NOT EXISTS 'grafana_ro'@'%' IDENTIFIED BY '$pw';
ALTER USER 'grafana_ro'@'%' IDENTIFIED BY '$pw' WITH MAX_USER_CONNECTIONS 5;
GRANT SELECT, SHOW VIEW ON \`$db\`.* TO 'grafana_ro'@'%';
SQL
    echo "mysql $ns: grafana_ro ok"
}

postgres_ro stocks pg-stocks-password
postgres_ro polymarket-bot pg-polymarket-password
mysql_ro stock-guesser stocker mysql-stockguesser-password
