#!/bin/bash
set -e



# Call before starting PostgreSQL
pg_fpw_off() {
    PG_DATA=$1
    sed -i "s/^#*full_page_writes = .*/full_page_writes = off/" "$PG_DATA/postgresql.conf"
}


# sed -i "s/^#*max_connections = .*/max_connections = 200/" "$PG_DATA/postgresql.conf"