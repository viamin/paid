#!/bin/bash
# Initialize multiple PostgreSQL databases for Paid and Temporal
# This script is run by the postgres container on first startup

set -e
set -u

POSTGRES_APP_USER="${POSTGRES_APP_USER:-}"
POSTGRES_APP_PASSWORD="${POSTGRES_APP_PASSWORD:-}"
POSTGRES_APP_DATABASES="${POSTGRES_APP_DATABASES:-}"

function create_app_role() {
    if [ -z "$POSTGRES_APP_USER" ]; then
        return
    fi

    echo "Ensuring application role '$POSTGRES_APP_USER'"
    psql -v ON_ERROR_STOP=1 \
        --username "$POSTGRES_USER" \
        --dbname "$POSTGRES_DB" \
        --set app_user="$POSTGRES_APP_USER" \
        --set app_password="$POSTGRES_APP_PASSWORD" <<-'EOSQL'
        SELECT format(
            'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB CREATEROLE NOBYPASSRLS',
            :'app_user',
            :'app_password'
        )
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_roles WHERE rolname = :'app_user'
        )\gexec

        ALTER ROLE :"app_user"
          WITH LOGIN PASSWORD :'app_password' NOSUPERUSER NOCREATEDB CREATEROLE NOBYPASSRLS;
EOSQL
}

function create_database() {
    local database=$1
    echo "Creating database '$database'"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        CREATE DATABASE "$database";
        GRANT ALL PRIVILEGES ON DATABASE "$database" TO $POSTGRES_USER;
EOSQL
}

function create_app_database() {
    local database=$1
    echo "Ensuring application database '$database'"
    psql -v ON_ERROR_STOP=1 \
        --username "$POSTGRES_USER" \
        --dbname "$POSTGRES_DB" \
        --set app_user="$POSTGRES_APP_USER" \
        --set app_database="$database" <<-'EOSQL'
        SELECT format('CREATE DATABASE %I OWNER %I', :'app_database', :'app_user')
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_database WHERE datname = :'app_database'
        )\gexec

        ALTER DATABASE :"app_database" OWNER TO :"app_user";
EOSQL

    psql -v ON_ERROR_STOP=1 \
        --username "$POSTGRES_USER" \
        --dbname "$database" \
        --set app_user="$POSTGRES_APP_USER" <<-'EOSQL'
        ALTER SCHEMA public OWNER TO :"app_user";
        GRANT ALL ON SCHEMA public TO :"app_user";
EOSQL
}

create_app_role

if [ -n "$POSTGRES_MULTIPLE_DATABASES" ]; then
    echo "Multiple database creation requested: $POSTGRES_MULTIPLE_DATABASES"
    for db in $(echo "$POSTGRES_MULTIPLE_DATABASES" | tr ',' ' '); do
        create_database "$db"
    done
    echo "Multiple databases created"
fi

if [ -n "$POSTGRES_APP_DATABASES" ]; then
    echo "Application database ownership requested: $POSTGRES_APP_DATABASES"
    for db in $(echo "$POSTGRES_APP_DATABASES" | tr ',' ' '); do
        create_app_database "$db"
    done
    echo "Application databases ready"
fi
