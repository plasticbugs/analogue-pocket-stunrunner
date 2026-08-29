cd projects
project_open stunrun_pocket -revision stunrun_pocket
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set paths [get_timing_paths -setup -npaths 15 -nworst 15]
foreach_in_collection p $paths {
    set s [get_path_info $p -slack]
    set f [get_node_info [get_path_info $p -from] -name]
    set t [get_node_info [get_path_info $p -to] -name]
    regsub {.*tms34010:gsp\|} $f "gsp|" f
    regsub {.*tms34010:gsp\|} $t "gsp|" t
    regsub {.*sdram_ctrl:sdram\|} $t "sdram|" t
    puts "SLK [format %.2f $s]  $f  ->  $t"
}
delete_timing_netlist
project_close
