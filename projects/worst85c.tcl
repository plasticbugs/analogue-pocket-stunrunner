cd projects
project_open stunrun_pocket -revision stunrun_pocket
create_timing_netlist -model slow -temperature 85 -voltage 1100
read_sdc
update_timing_netlist
set paths [get_timing_paths -setup -npaths 12 -nworst 12]
foreach_in_collection p $paths {
    puts "SLK [format %.2f [get_path_info $p -slack]]  [get_node_info [get_path_info $p -from] -name]  ->  [get_node_info [get_path_info $p -to] -name]"
}
delete_timing_netlist
project_close
