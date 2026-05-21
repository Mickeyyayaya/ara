# ==============================================================================
# Fixed Tcl Script for Synthesizing the Pipelined simd_pe module
# Comprehensive PPA (Power-Performance-Area) Analysis with Fair Comparison
# (Modified for PrimeTime PX Gate-Level Flow)
# ==============================================================================

# ==============================================================================
# SECTION 1: SETUP
# ==============================================================================
puts ">>>>> Synthesizing pipelined simd_pe for comprehensive PPA analysis..."

set DESIGN_NAME "simd_pe"

# Use a new directory for the pipelined design
set OUTPUT_DIR  "./output_synthesis_simd_pe_pipelined"
file mkdir $OUTPUT_DIR

# Essential RTL files for simd_pe
set RTL_FILES [list \
    "../../include/rvv_pkg.sv" \
    "../../include/ara_pkg.sv" \
    "simd_pe.sv" \
]

set LIB_PATH "/usr/cad/cell_lib/CBDK_TSMC40_Arm_f2.0/CIC/SynopsysDC"

# ==============================================================================
# SECTION 2: LIBRARY SETUP (STANDARDIZED FOR FAIR COMPARISON)
# ==============================================================================
set search_path [list . \
                     "${LIB_PATH}/db/sc9_base_rvt" \
                     "${LIB_PATH}/db/sc9_base_lvt" \
                     "${LIB_PATH}/db/sc9_base_hvt" \
                     "${LIB_PATH}/db/sc9_pmk_rvt" \
                     "${LIB_PATH}/db/sc9_pmk_lvt" \
                     "${LIB_PATH}/db/sc9_pmk_hvt" \
                     "/home/mickey/ara/hardware/include" \
                     "/home/mickey/ara/hardware/deps/common_cells/include" ]
                     
set target_library "sc9_cln40g_base_rvt_tt_typical_max_0p90v_25c.db"
set link_library [list "*" $target_library "dw_foundation.sldb"]

# ==============================================================================
# SECTION 3: STANDARDIZED CONSTANTS FOR FAIR COMPARISON
# ==============================================================================
# NAND2 gate area for TSMC 40nm standard cell library
set NAND2_AREA 1.2

# Clock period (ns) - STANDARDIZED across all designs
set CLK_PERIOD 6.0

# Voltage for power calculation - STANDARDIZED
set OPERATING_VOLTAGE 0.90

# Activity factor for power estimation - STANDARDIZED
set ACTIVITY_FACTOR 0.2

puts ">>>>> Standardized comparison parameters:"
puts "  NAND2 gate area:     $NAND2_AREA um^2"
puts "  Clock period:        $CLK_PERIOD ns"
puts "  Operating voltage:   $OPERATING_VOLTAGE V"
puts "  Activity factor:     $ACTIVITY_FACTOR"

# ==============================================================================
# SECTION 4: READ AND ELABORATE
# ==============================================================================
puts ">>>>> Reading and elaborating simd_pe..."

set hdlin_include_path [list \
    "/home/mickey/ara/hardware/include" \
    "/home/mickey/ara/hardware/deps/common_cells/include" \
]

# Analyze all files once
foreach rtl_file $RTL_FILES {
    if {[file exists $rtl_file]} {
        puts "Analyzing: $rtl_file"
        analyze -format sverilog $rtl_file
    } else {
        puts "ERROR: File not found: $rtl_file"
        exit 1
    }
}

# ==============================================================================
# SECTION 5: MULTIPLE CONFIGURATION SYNTHESIS
# ==============================================================================

# Configurations to synthesize for the pipelined design
set configs [list \
    [list "baseline_16L_4way_W2A8" "NumLanes=16, A_BITS=8, W_BITS=2, P_BITS=32, BufferDepth=4, UsePragmatic=0"] \
    [list "8L_4way_W2A8"           "NumLanes=8,  A_BITS=8, W_BITS=2, P_BITS=32, BufferDepth=4, UsePragmatic=0"] \
]

# ==============================================================================
# STANDARDIZED CONSTRAINT SETUP PROCEDURE (FIXED)
# ==============================================================================
proc apply_common_constraints {CLK_PERIOD} {
    # Clock definition with standardized uncertainty
    create_clock -period $CLK_PERIOD [get_ports clk_i]
    set_clock_uncertainty 0.5 [get_clocks clk_i]

    # I/O timing constraints (30% of clock period)
    set_input_delay  [expr $CLK_PERIOD * 0.3] -clock clk_i [remove_from_collection [all_inputs] [get_ports clk_i]]
    set_output_delay [expr $CLK_PERIOD * 0.3] -clock clk_i [all_outputs]

    # Ideal network for clock and reset
    set_ideal_network [get_ports clk_i]
    set_ideal_network [get_ports rst_ni]

    # Design rule constraints - STANDARDIZED
    set_max_fanout 16 [current_design]
    set_max_transition 1.0 [current_design]
    
    # Load constraints - STANDARDIZED
    set_load 0.1 [all_outputs]
    
    # Driving cell constraints - FIXED: Use specific cell instead of wildcard
    set input_ports [remove_from_collection [all_inputs] [get_ports -quiet {clk_i rst_ni}]]
    if {[sizeof_collection $input_ports] > 0} {
        # Try to find a buffer cell - use catch to handle if not found
        if {[catch {set buf_cell [get_lib_cells sc9_cln40g_base_rvt_tt_typical_max_0p90v_25c/BUFX2]}]} {
            puts "Warning: Could not find BUFX2, trying alternative..."
            if {[catch {set buf_cell [get_lib_cells sc9_cln40g_base_rvt_tt_typical_max_0p90v_25c/BUF*]} err]} {
                puts "Warning: Could not set driving cell: $err"
            } else {
                set_driving_cell -lib_cell [lindex $buf_cell 0] $input_ports
            }
        } else {
            set_driving_cell -lib_cell $buf_cell $input_ports
        }
    }
}

proc parse_synthesis_results {config_name NAND2_AREA CLK_PERIOD OPERATING_VOLTAGE} {
    set results [dict create]
    
    # -------------------------------------------------------------------------
    # 正確捕獲報告內容
    # -------------------------------------------------------------------------
    if {[catch {redirect -variable area_report { report_area }} err]} {
        puts "Warning: Failed to capture area report: $err"
        set area_report ""
    }
    
    if {[catch {redirect -variable timing_report { report_qor }} err]} {
        puts "Warning: Failed to capture timing report: $err"
        set timing_report ""
    }
    
    if {[catch {redirect -variable power_report { report_power }} err]} {
        puts "Warning: Failed to capture power report: $err"
        set power_report ""
    }
    
    # 調試：打印報告的前幾行
    puts "DEBUG: First 5 lines of area_report:"
    puts [join [lrange [split $area_report "\n"] 0 4] "\n"]
    
    # -------------------------------------------------------------------------
    # AREA ANALYSIS
    # -------------------------------------------------------------------------
    if {[regexp -line {^Total cell area:\s+([\d\.]+)} $area_report -> total_area]} {
        dict set results total_area [format "%.2f" $total_area]
        set gate_count [expr {$total_area / $NAND2_AREA}]
        dict set results gate_count [format "%.0f" $gate_count]
    } else {
        dict set results total_area "N/A"
        dict set results gate_count "N/A"
        puts "Warning: Could not parse total area from report"
    }
    
    if {[regexp -line {^Combinational area:\s+([\d\.]+)} $area_report -> comb_area]} {
        dict set results comb_area [format "%.2f" $comb_area]
        set comb_gates [expr {$comb_area / $NAND2_AREA}]
        dict set results comb_gates [format "%.0f" $comb_gates]
    } else {
        dict set results comb_area "N/A"
        dict set results comb_gates "N/A"
    }
    
    # Try both "Sequential area" and "Noncombinational area"
    if {[regexp -line {^Noncombinational area:\s+([\d\.]+)} $area_report -> seq_area]} {
        dict set results seq_area [format "%.2f" $seq_area]
        set seq_gates [expr {$seq_area / $NAND2_AREA}]
        dict set results seq_gates [format "%.0f" $seq_gates]
    } elseif {[regexp -line {^Sequential area:\s+([\d\.]+)} $area_report -> seq_area]} {
        dict set results seq_area [format "%.2f" $seq_area]
        set seq_gates [expr {$seq_area / $NAND2_AREA}]
        dict set results seq_gates [format "%.0f" $seq_gates]
    } else {
        dict set results seq_area "N/A"
        dict set results seq_gates "N/A"
    }
    
    # -------------------------------------------------------------------------
    # TIMING ANALYSIS
    # -------------------------------------------------------------------------
    # Try multiple patterns for WNS
    set wns_found 0
    if {[regexp {Critical Path Slack:\s+(-?[\d\.]+)} $timing_report -> wns]} {
        set wns_found 1
    } elseif {[regexp {Worst Negative Slack \(WNS\):\s+(-?[\d\.]+)} $timing_report -> wns]} {
        set wns_found 1
    } elseif {[regexp {slack \(VIOLATED\)\s+(-?[\d\.]+)} $timing_report -> wns]} {
        set wns_found 1
    }
    
    if {$wns_found} {
        dict set results wns [format "%.3f" $wns]
        # Calculate maximum frequency
        if {$wns >= 0} {
            set max_freq [expr {1000.0 / $CLK_PERIOD}]
        } else {
            set max_freq [expr {1000.0 / ($CLK_PERIOD - $wns)}]
        }
        dict set results max_freq [format "%.2f" $max_freq]
    } else {
        dict set results wns "N/A"
        dict set results max_freq "N/A"
        puts "Warning: Could not parse WNS from timing report"
        puts "DEBUG: First 10 lines of timing_report:"
        puts [join [lrange [split $timing_report "\n"] 0 9] "\n"]
    }
    
    # -------------------------------------------------------------------------
    # POWER ANALYSIS
    # -------------------------------------------------------------------------
    if {[regexp -line {^Total Dynamic Power\s*=\s*([\d\.]+)\s*([mnu]?W)} $power_report -> power_val power_unit]} {
        # Convert to mW
        if {$power_unit == "uW"} {
            set total_power [expr {$power_val / 1000.0}]
        } elseif {$power_unit == "nW"} {
            set total_power [expr {$power_val / 1000000.0}]
        } elseif {$power_unit == "mW"} {
            set total_power $power_val
        } elseif {$power_unit == "W"} {
            set total_power [expr {$power_val * 1000.0}]
        } else {
            set total_power $power_val
        }
        dict set results total_power [format "%.4f" $total_power]
    } else {
        dict set results total_power "N/A"
        puts "Warning: Could not parse total power"
    }
    
    if {[regexp -line {^Cell Leakage Power\s*=\s*([\d\.]+)\s*([mnu]?W)} $power_report -> leak_val leak_unit]} {
        # Convert to mW
        if {$leak_unit == "uW"} {
            set leakage_power [expr {$leak_val / 1000.0}]
        } elseif {$leak_unit == "nW"} {
            set leakage_power [expr {$leak_val / 1000000.0}]
        } elseif {$leak_unit == "mW"} {
            set leakage_power $leak_val
        } elseif {$leak_unit == "W"} {
            set leakage_power [expr {$leak_val * 1000.0}]
        } else {
            set leakage_power $leak_val
        }
        dict set results leakage_power [format "%.4f" $leakage_power]
    } else {
        dict set results leakage_power "N/A"
    }
    
    # -------------------------------------------------------------------------
    # DERIVED METRICS FOR COMPREHENSIVE COMPARISON
    # -------------------------------------------------------------------------
    
    # Calculate energy per cycle (pJ)
    if {[dict get $results total_power] ne "N/A"} {
        set energy_per_cycle [expr {[dict get $results total_power] * $CLK_PERIOD}]
        dict set results energy_per_cycle [format "%.4f" $energy_per_cycle]
    } else {
        dict set results energy_per_cycle "N/A"
    }
    
    # Calculate throughput (operations/sec)
    if {[dict get $results max_freq] ne "N/A"} {
        set throughput [expr {[dict get $results max_freq] * 1000000.0}]
        dict set results throughput [format "%.2e" $throughput]
    } else {
        dict set results throughput "N/A"
    }
    
    # Calculate area efficiency (GOPS/mm^2)
    if {[dict get $results total_area] ne "N/A" && [dict get $results max_freq] ne "N/A" && [dict get $results total_area] > 0} {
        set area_eff [expr {[dict get $results max_freq] / ([dict get $results total_area] / 1000000.0)}]
        dict set results area_efficiency [format "%.2f" $area_eff]
    } else {
        dict set results area_efficiency "N/A"
    }
    
    # Calculate energy efficiency (GOPS/W)
    if {[dict get $results total_power] ne "N/A" && [dict get $results max_freq] ne "N/A" && [dict get $results total_power] > 0} {
        set energy_eff [expr {[dict get $results max_freq] / ([dict get $results total_power] / 1000.0)}]
        dict set results energy_efficiency [format "%.2f" $energy_eff]
    } else {
        dict set results energy_efficiency "N/A"
    }
    
    # Calculate PPA product (lower is better)
    if {[dict get $results total_power] ne "N/A" && [dict get $results total_area] ne "N/A" && [dict get $results max_freq] ne "N/A" && [dict get $results max_freq] > 0} {
        set ppa [expr {([dict get $results total_power] * [dict get $results total_area]) / [dict get $results max_freq]}]
        dict set results ppa_product [format "%.4f" $ppa]
    } else {
        dict set results ppa_product "N/A"
    }
    
    return $results
}   

set results [dict create]

# ==============================================================================
# SYNTHESIS LOOP WITH STANDARDIZED POWER ANALYSIS (FIXED)
# ==============================================================================
foreach config $configs {
    set config_name [lindex $config 0]
    set config_params [lindex $config 1]
    
    puts "\n========================================================================"
    puts ">>>>> Synthesizing configuration: $config_name"
    puts ">>>>> Parameters: $config_params"
    puts "========================================================================"
    
    remove_design -all
    
    if {[catch {elaborate $DESIGN_NAME -parameters $config_params} err]} {
        puts "ERROR: Failed to elaborate $config_name: $err"
        continue
    }
    
    # Apply standardized constraints
    apply_common_constraints $CLK_PERIOD
    check_design
    
    # Set switching activity using get_nets
    if {[catch {
        set all_nets_collection [get_nets -hierarchical *]
        if {[sizeof_collection $all_nets_collection] > 0} {
            set_switching_activity -static_probability 0.5 -toggle_rate $ACTIVITY_FACTOR $all_nets_collection
        }
    } err]} {
        puts "Warning: Could not set switching activity: $err"
        puts "Continuing without switching activity settings..."
    }
    
    puts "Compiling $config_name with compile_ultra..."
    compile_ultra -no_autoungroup
    
    set config_dir "${OUTPUT_DIR}/${config_name}"
    file mkdir $config_dir
    
    # Generate comprehensive reports
    report_qor    > ${config_dir}/${DESIGN_NAME}_qor.rpt
    report_area   -hierarchy > ${config_dir}/${DESIGN_NAME}_area.rpt
    report_timing -max_paths 5 > ${config_dir}/${DESIGN_NAME}_timing.rpt
    report_power  -hierarchy > ${config_dir}/${DESIGN_NAME}_power.rpt
    report_resources > ${config_dir}/${DESIGN_NAME}_resources.rpt
    
    # ==========================================================================
    # EXPORT FILES FOR PRIMETIME PX (GATE-LEVEL SIMULATION & POWER ANALYSIS)
    # ==========================================================================
    
    # 1. 更改命名規則：消除 Verilog 不支援的特殊字元，避免 VCS/PT 報錯
    change_names -rules verilog -hierarchy
    
    # 2. 輸出 Gate-level Netlist
    write -format verilog -hierarchy -output ${config_dir}/${DESIGN_NAME}_netlist.v
    
    # 3. 輸出 SDF (Standard Delay Format) - 精準分析 Glitch 功耗的核心
    write_sdf -version 2.1 ${config_dir}/${DESIGN_NAME}_syn.sdf
    
    # 4. 輸出 SDC (Synopsys Design Constraints) - 給 PT 重建時脈約束
    write_sdc ${config_dir}/${DESIGN_NAME}_syn.sdc
    
    # 5. 輸出 DDC 
    write -format ddc -hierarchy -output ${config_dir}/${DESIGN_NAME}.ddc
    
    # ==========================================================================
    
    # Parse and store results with comprehensive metrics
    set config_results [parse_synthesis_results $config_name $NAND2_AREA $CLK_PERIOD $OPERATING_VOLTAGE]
    dict set results $config_name $config_results
    
    puts "Configuration $config_name completed."
    puts "  Total Gates:    [dict get $config_results gate_count]"
    puts "  Total Area:     [dict get $config_results total_area] um^2"
    puts "  Total Power:    [dict get $config_results total_power] mW"
    puts "  Max Frequency:  [dict get $config_results max_freq] MHz"
}

# ==============================================================================
# SECTION 6: COMPREHENSIVE PPA COMPARISON TABLES
# ==============================================================================
puts "\n>>>>> Generating comprehensive PPA comparison tables..."

redirect ${OUTPUT_DIR}/simd_pe_comprehensive_comparison.txt {
    puts "==================================================================================="
    puts "           Pipelined SIMD_PE Comprehensive PPA Analysis"
    puts "           STANDARDIZED COMPARISON CONDITIONS"
    puts "==================================================================================="
    puts "Clock Period:        ${CLK_PERIOD} ns"
    puts "Operating Voltage:   ${OPERATING_VOLTAGE} V"
    puts "Activity Factor:     ${ACTIVITY_FACTOR}"
    puts "NAND2 Gate:          ${NAND2_AREA} um^2"
    puts "Technology:          TSMC 40nm"
    puts "==================================================================================="
    puts ""
    
    # TABLE 1: GATE COUNT AND AREA
    puts "TABLE 1: GATE COUNT AND AREA ANALYSIS"
    puts "-----------------------------------------------------------------------------------"
    puts [format "%-25s | %12s | %12s | %12s | %12s" \
        "Configuration" "Total Gates" "Total Area" "Comb Gates" "Seq Gates"]
    puts [format "%-25s | %12s | %12s | %12s | %12s" \
        "" "(NAND2 eq)" "(um^2)" "(NAND2 eq)" "(NAND2 eq)"]
    puts "-----------------------------------------------------------------------------------"
    
    foreach config_name [lsort [dict keys $results]] {
        set config_results [dict get $results $config_name]
        puts [format "%-25s | %12s | %12s | %12s | %12s" \
            $config_name \
            [dict get $config_results gate_count] \
            [dict get $config_results total_area] \
            [dict get $config_results comb_gates] \
            [dict get $config_results seq_gates]]
    }
    puts "-----------------------------------------------------------------------------------"
    puts ""
    
    # TABLE 2: POWER ANALYSIS
    puts "TABLE 2: POWER ANALYSIS"
    puts "-----------------------------------------------------------------------------------"
    puts [format "%-25s | %15s | %15s | %15s" \
        "Configuration" "Total Power" "Leakage Power" "Energy/Cycle"]
    puts [format "%-25s | %15s | %15s | %15s" \
        "" "(mW)" "(mW)" "(pJ)"]
    puts "-----------------------------------------------------------------------------------"
    
    foreach config_name [lsort [dict keys $results]] {
        set config_results [dict get $results $config_name]
        puts [format "%-25s | %15s | %15s | %15s" \
            $config_name \
            [dict get $config_results total_power] \
            [dict get $config_results leakage_power] \
            [dict get $config_results energy_per_cycle]]
    }
    puts "-----------------------------------------------------------------------------------"
    puts ""
    
    # TABLE 3: PERFORMANCE ANALYSIS
    puts "TABLE 3: PERFORMANCE AND TIMING ANALYSIS"
    puts "-----------------------------------------------------------------------------------"
    puts [format "%-25s | %15s | %15s | %15s" \
        "Configuration" "WNS (ns)" "Max Freq (MHz)" "Throughput (Ops/s)"]
    puts "-----------------------------------------------------------------------------------"
    
    foreach config_name [lsort [dict keys $results]] {
        set config_results [dict get $results $config_name]
        set wns [dict get $config_results wns]
        puts [format "%-25s | %15s | %15s | %15s" \
            $config_name \
            $wns \
            [dict get $config_results max_freq] \
            [dict get $config_results throughput]]
    }
    puts "-----------------------------------------------------------------------------------"
    puts ""
    
    # TABLE 4: EFFICIENCY METRICS
    puts "TABLE 4: EFFICIENCY METRICS (HIGHER IS BETTER)"
    puts "-----------------------------------------------------------------------------------"
    puts [format "%-25s | %18s | %18s" \
        "Configuration" "Area Efficiency" "Energy Efficiency"]
    puts [format "%-25s | %18s | %18s" \
        "" "(GOPS/mm^2)" "(GOPS/W)"]
    puts "-----------------------------------------------------------------------------------"
    
    foreach config_name [lsort [dict keys $results]] {
        set config_results [dict get $results $config_name]
        puts [format "%-25s | %18s | %18s" \
            $config_name \
            [dict get $config_results area_efficiency] \
            [dict get $config_results energy_efficiency]]
    }
    puts "-----------------------------------------------------------------------------------"
    puts ""
    
    # TABLE 5: PPA PRODUCT (LOWER IS BETTER)
    puts "TABLE 5: PPA PRODUCT ANALYSIS (LOWER IS BETTER)"
    puts "-----------------------------------------------------------------------------------"
    puts [format "%-25s | %20s" \
        "Configuration" "PPA Product"]
    puts [format "%-25s | %20s" \
        "" "(mW*um^2/MHz)"]
    puts "-----------------------------------------------------------------------------------"
    
    foreach config_name [lsort [dict keys $results]] {
        set config_results [dict get $results $config_name]
        puts [format "%-25s | %20s" \
            $config_name \
            [dict get $config_results ppa_product]]
    }
    puts "-----------------------------------------------------------------------------------"
    puts ""
    
    # DETAILED ANALYSIS NOTES
    puts "==================================================================================="
    puts "DETAILED ANALYSIS"
    puts "==================================================================================="
    puts ""
    puts "Architecture Overview (Sub-word SIMD W2A8):"
    puts "  - 64x Booth-encoded multipliers (16 Lanes * 4 ways)"
    puts "  - 16x 4-input Internal Adders + 16-to-1 Global Adder Tree"
    puts "  - 3-stage pipeline (S0: Decode, S1: Multiply, S2: Accumulate)"
    puts ""
    puts "Power Breakdown:"
    puts "  - Dynamic power: Dominated by switching activity in multipliers and adders"
    puts "  - Leakage power: Increases with total gate count"
    puts "  - Energy/cycle: Product of power and clock period"
    puts ""
    puts "Scaling Analysis:"
    puts "  - Area scales linearly with number of lanes"
    puts "  - Power scales linearly with number of lanes"
    puts "  - Frequency remains relatively constant (limited by critical path)"
    puts ""
    puts "==================================================================================="
}

# ==============================================================================
# SECTION 7: GENERATE CSV FOR EXTERNAL ANALYSIS
# ==============================================================================
puts "\n>>>>> Generating CSV file for external analysis..."

set csv_file [open "${OUTPUT_DIR}/synthesis_results.csv" w]
puts $csv_file "Configuration,NumLanes,TotalGates,TotalArea_um2,CombGates,SeqGates,TotalPower_mW,LeakagePower_mW,EnergyPerCycle_pJ,MaxFreq_MHz,WNS_ns,Throughput_Ops_s,AreaEfficiency_GOPS_mm2,EnergyEfficiency_GOPS_W,PPA_Product"

foreach config_name [lsort [dict keys $results]] {
    set config_results [dict get $results $config_name]
    
    # Extract number of lanes from config name
    if {[regexp {(\d+)lanes} $config_name -> num_lanes]} {
        set lanes $num_lanes
    } else {
        set lanes "N/A"
    }
    
    puts $csv_file "$config_name,$lanes,[dict get $config_results gate_count],[dict get $config_results total_area],[dict get $config_results comb_gates],[dict get $config_results seq_gates],[dict get $config_results total_power],[dict get $config_results leakage_power],[dict get $config_results energy_per_cycle],[dict get $config_results max_freq],[dict get $config_results wns],[dict get $config_results throughput],[dict get $config_results area_efficiency],[dict get $config_results energy_efficiency],[dict get $config_results ppa_product]"
}

close $csv_file

# ==============================================================================
# SECTION 8: FINAL SUMMARY
# ==============================================================================
puts "\n========================================================================"
puts ">>>>> Pipelined SIMD_PE comprehensive PPA analysis complete!"
puts "========================================================================"
puts ""
puts "RESULTS SUMMARY:"
puts "================"
puts "Main output directory: $OUTPUT_DIR"
puts ""
puts "Generated files:"
puts "  1. Comprehensive analysis: ${OUTPUT_DIR}/simd_pe_comprehensive_comparison.txt"
puts "  2. CSV for plotting:       ${OUTPUT_DIR}/synthesis_results.csv"
puts "  3. Per-config reports:     ${OUTPUT_DIR}/<config_name>/*"
puts "  4. Gate-Level files:       ${OUTPUT_DIR}/<config_name>/*_netlist.v, *.sdf, *.sdc"
puts ""

# Find best configurations by different metrics
set min_area 999999
set min_power 999999
set max_efficiency 0
set best_area_config ""
set best_power_config ""
set best_eff_config ""

foreach config_name [dict keys $results] {
    set config_results [dict get $results $config_name]
    
    # Best area
    set area [dict get $config_results total_area]
    if {$area ne "N/A" && $area < $min_area} {
        set min_area $area
        set best_area_config $config_name
    }
    
    # Best power
    set power [dict get $config_results total_power]
    if {$power ne "N/A" && $power < $min_power} {
        set min_power $power
        set best_power_config $config_name
    }
    
    # Best energy efficiency
    set eff [dict get $config_results energy_efficiency]
    if {$eff ne "N/A" && $eff > $max_efficiency} {
        set max_efficiency $eff
        set best_eff_config $config_name
    }
}

puts "OPTIMAL CONFIGURATIONS:"
puts "======================="
if {$best_area_config ne ""} {
    set best_results [dict get $results $best_area_config]
    puts "Best Area: $best_area_config"
    puts "  Total Area:  [dict get $best_results total_area] um^2"
    puts "  Total Gates: [dict get $best_results gate_count]"
    puts ""
}

if {$best_power_config ne ""} {
    set best_results [dict get $results $best_power_config]
    puts "Best Power: $best_power_config"
    puts "  Total Power: [dict get $best_results total_power] mW"
    puts "  Energy/Cyc:  [dict get $best_results energy_per_cycle] pJ"
    puts ""
}

if {$best_eff_config ne ""} {
    set best_results [dict get $results $best_eff_config]
    puts "Best Energy Efficiency: $best_eff_config"
    puts "  Energy Eff:  [dict get $best_results energy_efficiency] GOPS/W"
    puts "  Area Eff:    [dict get $best_results area_efficiency] GOPS/mm^2"
    puts ""
}

puts "STANDARDIZED COMPARISON CONDITIONS:"
puts "==================================="
puts "  - Clock Period:      ${CLK_PERIOD} ns (166 MHz)"
puts "  - Operating Voltage: ${OPERATING_VOLTAGE} V"
puts "  - Activity Factor:   ${ACTIVITY_FACTOR}"
puts "  - Library:           TSMC 40nm RVT"
puts "  - Compiler:          compile_ultra -no_autoungroup"
puts ""
puts "All designs synthesized under identical conditions for fair comparison."
puts "========================================================================"

exit