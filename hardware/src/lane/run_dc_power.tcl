# ==============================================================================
# Gate-Level Power Analysis Script for dc_shell (Batch Automated Flow)
# Comprehensive evaluation across multiple LLM models and layers
# ==============================================================================

puts "Starting batch dc_shell Gate-Level Power Analysis..."

# ------------------------------------------------------------------------------
# Section 1: Environment and Target Technology Library Setup
# ------------------------------------------------------------------------------
set DESIGN_NAME "simd_pe"
set LIB_PATH    "/usr/cad/cell_lib/CBDK_TSMC40_Arm_f2.0/CIC/SynopsysDC"

set search_path [list . \
                     "${LIB_PATH}/db/sc9_base_rvt" \
                     "/home/mickey/ara/hardware/include" ]
                     
set target_library "sc9_cln40g_base_rvt_tt_typical_max_0p90v_25c.db"
set link_library   [list "*" $target_library "dw_foundation.sldb"]

# ------------------------------------------------------------------------------
# Section 2: Directory Configuration
# ------------------------------------------------------------------------------
set CONFIG_NAME "baseline_16L_4way_W2A8"
set SYN_DIR     "./output_synthesis_simd_pe_pipelined/${CONFIG_NAME}"
set DC_PWR_DIR  "./output_dc_power_${CONFIG_NAME}"

# Create output directory for power reports if it does not exist
file mkdir $DC_PWR_DIR

# ------------------------------------------------------------------------------
# Section 3: Defining Target Workloads (9 Models and 7 Layers)
# ------------------------------------------------------------------------------
set models [list \
    "microsoft__bitnet-b1.58-2B-4T" \
    "1bitLLM__bitnet_b1_58-large" \
    "1bitLLM__bitnet_b1_58-3B" \
    "HF1BitLLM__Llama3-8B-1.58-100B-tokens" \
    "tiiuae__Falcon3-10B-Base" \
    "tiiuae__Falcon-E-3B-Base" \
    "SparseLLM__ReluLLaMA-7B" \
    "SparseLLM__ReluLLaMA-70B" \
    "SparseLLM__ReluFalcon-40B" \
]

set layers [list \
    "q_proj" \
    "k_proj" \
    "v_proj" \
    "o_proj" \
    "gate_proj" \
    "up_proj" \
    "down_proj" \
]

# ------------------------------------------------------------------------------
# Section 4: Automated Execution Loop
# ------------------------------------------------------------------------------
foreach model $models {
    foreach layer $layers {
        
        puts "----------------------------------------------------------------"
        puts "Processing Workload: Model = $model | Layer = $layer"
        puts "----------------------------------------------------------------"
        
        set SAIF_FILE "pe_${model}_${layer}.saif"
        
        # Check if the specific SAIF file exists before loading the database
        if {![file exists $SAIF_FILE]} {
            puts "WARNING: SAIF file $SAIF_FILE not found. Skipping to next workload."
            continue
        }
        
        # Reset Design Compiler state to prevent switching activity accumulation
        remove_design -all
        
        # Read the compiled DDC which contains netlist and name mapping information
        if {[catch {read_ddc "${SYN_DIR}/${DESIGN_NAME}.ddc"} err]} {
            puts "ERROR: Failed to read DDC database for $model | $layer : $err"
            continue
        }
        
        current_design $DESIGN_NAME
        link
        
        # Read constraint and timing files
        read_sdc "${SYN_DIR}/${DESIGN_NAME}_syn.sdc"
        read_sdf "${SYN_DIR}/${DESIGN_NAME}_syn.sdf"
        
        # Annotate switching activity from the generated GLS SAIF file
        puts "Annotating activity from: $SAIF_FILE"
        read_saif -input $SAIF_FILE -instance "arch_showdown_tb/dut_pe" -verbose
        
        # Generate targeted power reports
        puts "Generating Power Reports in Design Compiler..."
        
        set hierarchy_rpt "${DC_PWR_DIR}/dc_power_hierarchy_${model}_${layer}.rpt"
        set detailed_rpt  "${DC_PWR_DIR}/dc_power_detailed_${model}_${layer}.rpt"
        
        report_power -hierarchy > $hierarchy_rpt
        report_power -analysis_effort high > $detailed_rpt
        
        puts "Workload $model ($layer) completed successfully."
    }
}

puts "========================================================================"
puts "Batch Power Analysis Routine Completed Successfully!"
puts "Reports generated in directory: $DC_PWR_DIR"
puts "========================================================================"

exit