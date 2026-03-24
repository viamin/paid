#!/bin/bash
# Stop the local PostgreSQL server
PGBINDIR=/workspace/.pg-install/pg16-extracted/usr/lib/postgresql/16/bin
PGDATA=/workspace/.pg-data
export LD_LIBRARY_PATH=/workspace/.pg-install/lib

$PGBINDIR/pg_ctl -D "$PGDATA" stop
