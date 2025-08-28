puts "SETTING CONFIGURATION"
dbset db pg
dbset bm TPC-C
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
diset tpcc pg_total_iterations __ITERATIONS__
diset tpcc pg_rampup __RAMPUP__
diset tpcc pg_duration __DURATION__

loadscript

puts "TEST STARTED"
vuset vu __VU__
vucreate
tcstart
tcstatus
set jobid [ vurun ]
tcstop
vudestroy
puts "TEST COMPLETE"
puts "Job ID: $jobid"
