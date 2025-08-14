puts "Setting up PostgreSQL TPC-C build"
dbset db pg
diset connection pg_host localhost
diset connection pg_port 5432

diset tpcc pg_user tpccuser
diset tpcc pg_pass tpccpass
diset tpcc pg_superuser tpccuser
diset tpcc pg_superuserpass tpccpass
diset tpcc pg_defaultdbase tpccdb
diset tpcc pg_dbase tpccdb

diset tpcc pg_tspace pg_default
diset tpcc pg_count_ware __WAREHOUSE__
diset tpcc pg_num_vu __VU__
diset tpcc pg_storedprocs __STOREDPROCS__
diset tpcc pg_partition false

vudestroy
buildschema
