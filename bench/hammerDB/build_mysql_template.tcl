puts "Setting up MySQL TPC-C build"
dbset db mysql
diset connection mysql_host localhost
diset connection mysql_port 3306
diset connection mysql_socket __MYSOCKET__

diset tpcc mysql_user tpccuser
diset tpcc mysql_pass tpccpass
diset tpcc mysql_dbase tpccdb

diset tpcc mysql_count_ware __WAREHOUSE__
diset tpcc mysql_num_vu __VU__

vudestroy
buildschema
