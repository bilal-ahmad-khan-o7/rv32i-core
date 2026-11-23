# build.tcl - synthesise, place and route top_kws for the PYNQ-Z2 (xc7z020clg400-1) in
# Vivado's non-project (batch) mode, then write the timing and utilisation reports.
#
#   vivado -mode batch -source fpga/build.tcl -tclargs pipelined
#   vivado -mode batch -source fpga/build.tcl -tclargs single_cycle
#   vivado -mode batch -source fpga/build.tcl -tclargs pipelined dsp
#
# "dsp" defines NN_USE_DSP, which asks for DOT4.S8's four lane products in DSP blocks
# (nn_unit.sv); the logic is the same. Without it the flow is as before.
#
# Every path is resolved from this script's own location, so it runs from any current
# directory and any copy of the repository. Results go to fpga/out/<core>/ (with "dsp":
# fpga/out/<core>_dsp/); summary.txt has the maximum clock, the slowest paths and the
# resource counts.
# Uses only commands Vivado 2019.1 already had, and nothing outside the free licence.

if {[llength $argv] ni {1 2} || [lindex $argv 0] ni {pipelined single_cycle}
    || ([llength $argv] == 2 && [lindex $argv 1] ne "dsp")} {
    puts "usage: vivado -mode batch -source fpga/build.tcl -tclargs pipelined|single_cycle \[dsp\]"
    exit 1
}
set core [lindex $argv 0]
set dsp  [expr {[llength $argv] == 2}]
set fpga [file dirname [file normalize [info script]]]
set repo [file dirname $fpga]
set out  [file join $fpga out [expr {$dsp ? "${core}_dsp" : $core}]]
set part xc7z020clg400-1
file mkdir $out
# Vivado writes scratch files (.Xil/, clockInfo.txt, ...) to the current directory; keep them
# with the results. Every path below is absolute.
cd $out

# ---- sources: keep these lists in step with each core's sim/run_tests.py ----------
set sc [file join $repo single_cycle rtl]
set pl [file join $repo pipelined rtl]
if {$core eq "pipelined"} {
    set files [list [file join $sc riscv_pkg.sv] [file join $pl pipeline_pkg.sv]]
    foreach m {pc_reg regfile imm_gen alu control branch_unit lsu mul_unit nn_unit id_stage ex_stage wb_stage} {
        lappend files [file join $sc $m.sv]
    }
    foreach m {imem dmem if_stage mem_stage if_id_reg id_ex_reg ex_mem_reg mem_wb_reg
               hazard_unit forward_unit rf_bypass riscv_core} {
        lappend files [file join $pl $m.sv]
    }
} else {
    set files [list [file join $sc riscv_pkg.sv]]
    foreach m {pc_reg imem regfile dmem imm_gen alu control branch_unit lsu mul_unit nn_unit
               if_stage id_stage ex_stage mem_stage wb_stage riscv_core} {
        lappend files [file join $sc $m.sv]
    }
}
foreach m {clock_gen reset_sync top_kws} {
    lappend files [file join $fpga rtl $m.sv]
}

# KWS build (c) and one recording, so that nothing is optimised away
set imem [file join $repo kws gen kws_c.imem.hex]
set dmem [file join $fpga mem kws_c_dmem_tst_000007_Yes_9.hex]
foreach f [concat $files [list $imem $dmem [file join $fpga pynq_z2.xdc]]] {
    if {![file exists $f]} {
        puts "missing file: $f"
        exit 1
    }
}

set log [open [file join $out summary.txt] w]
proc note {msg} {
    global log
    puts $msg
    puts $log $msg
    flush $log
}
# a property of a timing path, or "?" if this Vivado version does not have it
proc prop {obj name} {
    if {[catch {get_property $name $obj} v]} { return "?" }
    return $v
}
proc step {name script} {
    if {[catch {uplevel 1 $script} msg]} {
        note "FAILED in $name: $msg"
        return 0
    }
    return 1
}

note "core: $core   part: $part   Vivado [version -short]"
if {$dsp} { note "variant: dsp (NN_USE_DSP: DOT4.S8's lane products in DSP blocks)" }

read_verilog -sv $files
read_xdc [file join $fpga pynq_z2.xdc]

# The memory images are string parameters of top_kws; a Verilog string value keeps its quotes.
set synth_args [list -top top_kws -part $part -generic "IMEM_FILE=\"$imem\"" -generic "DMEM_FILE=\"$dmem\""]
if {$dsp} { lappend synth_args -verilog_define NN_USE_DSP }
if {![step synth_design {
    synth_design {*}$synth_args
}]} {
    close $log
    exit 1
}
report_utilization -file [file join $out utilization_synth.rpt]

set placed [expr {[step opt_design {opt_design}] && [step place_design {place_design}]}]
set routed [expr {$placed && [step route_design {route_design}]}]
if {!$routed} {
    note "the design did not place or route: see utilization_synth.rpt and the Vivado log"
    if {$placed} { report_utilization -file [file join $out utilization.rpt] }
    close $log
    exit 1
}
write_checkpoint -force [file join $out routed.dcp]

report_timing_summary -max_paths 10 -report_unconstrained -file [file join $out timing_summary.rpt]
report_timing -max_paths 10 -nworst 1 -sort_by slack -path_type full -file [file join $out critical_paths.rpt]
report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -file [file join $out utilization_hier.rpt]

# ---- summary: maximum clock, the slowest paths, the resources -----------------------
set paths  [get_timing_paths -setup -max_paths 10 -nworst 1 -sort_by slack]
set worst  [lindex $paths 0]
set clk    [prop $worst ENDPOINT_CLOCK]
set period [get_property PERIOD [get_clocks $clk]]
set wns    [prop $worst SLACK]
note ""
note "clock $clk: period $period ns, worst setup slack (WNS) $wns ns"
note [format "maximum clock: %.1f MHz   (1 / (period - WNS))" [expr {1000.0 / ($period - $wns)}]]
note ""
note "slowest path:"
note "  from   [prop $worst STARTPOINT_PIN]"
note "  to     [prop $worst ENDPOINT_PIN]"
note "  logic levels [prop $worst LOGIC_LEVELS]; data path [prop $worst DATAPATH_DELAY] ns =\
 logic [prop $worst DATAPATH_LOGIC_DELAY] ns + routing [prop $worst DATAPATH_NET_DELAY] ns"
note ""
note "the 10 slowest paths (slack ns, logic levels, start -> end):"
foreach p $paths {
    note "  [prop $p SLACK]  [prop $p LOGIC_LEVELS]  [prop $p STARTPOINT_PIN] -> [prop $p ENDPOINT_PIN]"
}
note ""
note "resources (from report_utilization):"
set seen {}
foreach line [split [report_utilization -return_string] "\n"] {
    # the first row of each name only: some rows appear again in a later section
    if {[regexp {^\|\s*(Slice LUTs|Slice Registers|LUT as Logic|LUT as Memory|Block RAM Tile|DSPs)\*?\s*\|} $line -> name]
        && $name ni $seen} {
        lappend seen $name
        note "  $line"
    }
}
close $log
puts "reports are in $out"
