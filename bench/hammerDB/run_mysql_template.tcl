puts "SETTING CONFIGURATION"
dbset db mysql
dbset bm TPC-C
diset connection mysql_host localhost
diset connection mysql_port 3306
diset connection mysql_socket __MYSOCKET__

diset tpcc mysql_user tpccuser
diset tpcc mysql_pass tpccpass
diset tpcc mysql_dbase tpccdb

diset tpcc mysql_count_ware __WAREHOUSE__
diset tpcc mysql_num_vu __VU__
diset tpcc mysql_total_iterations __ITERATIONS__
diset tpcc mysql_rampup __RAMPUP__
diset tpcc mysql_duration __DURATION__

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
