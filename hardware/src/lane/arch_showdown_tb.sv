`timescale 1ns/10ps

module arch_showdown_tb;

  // Import necessary packages
  import ara_pkg::*;
  import rvv_pkg::*;

  /////////////////////////////////////////////////////////
  // Global Parameters 
  /////////////////////////////////////////////////////////
  localparam int unsigned ClockPeriod = 6; 
  localparam int unsigned A_BITS = 8;
  localparam int unsigned W_BITS = 2;
  localparam int unsigned NumLanes = 16;
  localparam int unsigned NumPairs = 16; 
  localparam int unsigned BufferDepth = 64; 
  localparam int unsigned WEIGHT_PACKING_FACTOR = 8 / W_BITS; 

  localparam string BASE_PATH = "/home/mickey/ara/hardware/src/lane/model_realistic_op_data/";

  // Memory & System Params
  localparam int unsigned VLEN_BITS = 4096;
  localparam int unsigned AXI_DATA_WIDTH = 512;
  localparam int unsigned BEATS_PER_VLEN = VLEN_BITS / AXI_DATA_WIDTH; 
  localparam int unsigned CYCLES_PER_VLEN = VLEN_BITS / (NumPairs * A_BITS); 
  
  localparam int unsigned VLSU_AR_LATENCY        = 2;  
  localparam int unsigned VLSU_VRF_WRITE_LATENCY = 3;
  localparam int unsigned VLSU_AW_LATENCY        = 2;
  localparam int unsigned VLSU_B_RESPONSE        = 3;
  localparam int unsigned ARA_DISPATCH_CYCLES    = 25;

  localparam int unsigned CACHE_HIT_LATENCY  = 2;   
  localparam int unsigned CACHE_MISS_LATENCY = 50;  
  localparam int unsigned MEM_LATENCY_VARIATION = 5;
  localparam int unsigned ACT_CACHE_HIT_RATE = 95;  
  localparam int unsigned WGT_CACHE_HIT_RATE = 10;  

  /////////////////////////////////////////////////////////
  // Test Data & Models
  /////////////////////////////////////////////////////////
  typedef struct { string model_name; string test_files[]; } model_t;
  model_t models[];

  string current_test_file, current_test_name, current_model_name;
  string saif_out_name;
  logic signed [7:0] input_data [0:15000000]; 
  logic [1:0]        weight_data[0:15000000];
  integer            input_num, fp_r, dummy_var, idx;

  /////////////////////////////////////////////////////////
  // DUT Signals (Separated for 3 Architectures)
  /////////////////////////////////////////////////////////
  logic clk_i, rst_ni;
  
  // 1. Traditional RVV
  logic        valid_i_rvv, ready_o_rvv, valid_o_rvv;
  elen_t       opa_rvv, opb_rvv;
  logic [7:0]  mask_o_rvv;
  elen_t       result_o_rvv;
  
  // 2. T-MAC
  logic        valid_i_tmac, ready_o_tmac, valid_o_tmac;
  elen_t       opa_tmac, opb_tmac;
  logic [7:0]  mask_o_tmac;
  elen_t       result_o_tmac;
  
  // 3. Custom SIMD_PE
  logic        valid_i_pe, ready_o_pe, valid_o_pe;
  elen_t       opa_pe, opb_pe;
  logic [7:0]  mask_o_pe;
  logic [3:0][31:0] result_o_pe;

  // Common settings
  elen_t       operand_c_i = '0;
  logic [7:0]  mask_i = '1;
  vxrm_t       vxrm_i = 2'b00;
  vxsat_t      vxsat_o_rvv, vxsat_o_tmac, vxsat_o_pe;

  /////////////////////////////////////////////////////////
  // Instantiate 3 Architectures
  /////////////////////////////////////////////////////////
  
  // [1] Traditional RVV (No Packing, Software Unpack Penalty)
  simd_mul #(.ElementWidth(EW8)) dut_rvv (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .operand_a_i(opa_rvv), .operand_b_i(opb_rvv), .operand_c_i(operand_c_i),
    .mask_i(mask_i), .op_i(VMUL), .result_o(result_o_rvv), .mask_o(mask_o_rvv),
    .vxsat_o(vxsat_o_rvv), .vxrm_i(vxrm_i),
    .valid_i(valid_i_rvv), .ready_o(ready_o_rvv), .ready_i(1'b1), .valid_o(valid_o_rvv)
  );

  // [2] T-MAC (LUT Generation Overhead)
  simd_tmac #(.NumPipeRegs(2), .GroupSize(4)) dut_tmac (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .operand_a_i(opa_tmac), .operand_b_i(opb_tmac), .operand_c_i(operand_c_i),
    .mask_i(mask_i), .op_i(VTMUL2), .vew_i(EW8), .result_o(result_o_tmac), .mask_o(mask_o_tmac),
    .vxsat_o(vxsat_o_tmac), .vxrm_i(vxrm_i),
    .valid_i(valid_i_tmac), .ready_o(ready_o_tmac), .ready_i(1'b1), .valid_o(valid_o_tmac)
  );

  // [3] Custom SIMD_PE (1-to-4 HW Broadcast & Zero-Skipping)
  simd_pe #(.NumLanes(NumLanes), .BufferDepth(BufferDepth)) dut_pe (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .operand_a_i(opa_pe), .operand_b_i(opb_pe), .operand_c_i(operand_c_i),
    .mask_i(mask_i), .op_i(VMUL), .vew_i(EW8), .result_o(result_o_pe), .mask_o(mask_o_pe),
    .vxsat_o(vxsat_o_pe), .vxrm_i(vxrm_i),
    .valid_i(valid_i_pe), .ready_o(ready_o_pe), .ready_i(1'b1), .valid_o(valid_o_pe)
  );

  /////////////////////////////////////////////////////////
  // Metrics & Results Struct
  /////////////////////////////////////////////////////////
  typedef struct {
    string model_name;
    integer data_sizes[string];
    
    integer rvv_cycles[string];
    integer tmac_cycles[string];
    integer pe_cycles[string];
    
    real    rvv_gmacs[string];
    real    tmac_gmacs[string];
    real    pe_gmacs[string];
    
    real    pe_power_saving[string];

    // Energy metrics tracked in microjoules (uJ)
    real    rvv_energy[string];
    real    tmac_energy[string];
    real    pe_energy[string];
    real    pe_energy_saved[string];
  } result_t;

  result_t results[];
  integer current_model_idx;

  integer cycles;
  initial begin clk_i = 0; forever #(ClockPeriod / 2) clk_i = ~clk_i; end
  always @(posedge clk_i) if (!rst_ni) cycles <= 0; else cycles <= cycles + 1;

  /////////////////////////////////////////////////////////
  // Tasks
  /////////////////////////////////////////////////////////
  task automatic reset_duts();
    rst_ni = 1'b0; 
    valid_i_rvv = 1'b0; valid_i_tmac = 1'b0; valid_i_pe = 1'b0;
    repeat (5) @(posedge clk_i); rst_ni = 1'b1; @(posedge clk_i);
  endtask

  task automatic read_testdata();
    fp_r = $fopen(current_test_file, "r");
    if (fp_r == 0) begin $display("Error: Cannot open %s", current_test_file); return; end
    dummy_var = $fscanf(fp_r, "%d", input_num);
    for (idx = 0; idx < input_num; idx++) dummy_var = $fscanf(fp_r, "%d", input_data[idx]);
    for (idx = 0; idx < input_num; idx++) dummy_var = $fscanf(fp_r, "%d", weight_data[idx]);
    $fclose(fp_r);
  endtask

  // ============================================================
  // Execution Task with Analytical Energy Model Evaluation
  // ============================================================
  task automatic run_showdown_test();
    integer total_pe_batches;
    integer total_vlen_chunks;
    
    integer rvv_start, tmac_start, pe_start;
    integer rvv_end, tmac_end, pe_end;
    
    integer total_mac_ops;
    integer skipped_zero_ops;

    real time_rvv, time_tmac, time_pe;
    real gmacs_rvv, gmacs_tmac, gmacs_pe;
    real power_saved_percent;
    integer base_hit_rate;

    // --- Analytical Energy Model Parameters (pJ) ---
    real PJ_PER_CYCLE_RVV  = 15.0; 
    real PJ_PER_CYCLE_TMAC = 18.0; 
    real PJ_PER_CYCLE_PE   = 10.0; 
    real PJ_PER_MAC_ACTIVE = 2.5;  
    real PJ_PER_MAC_GATED  = 0.1;  

    real total_energy_pj_rvv, total_energy_pj_tmac;
    real total_energy_pj_pe, saved_energy_pj_pe;

    if (input_num == 0) return;

    $display("\n============================================================");
    $display("[RACE START] Testing: %s", current_test_name);
    
    total_pe_batches = (input_num + NumPairs - 1) / NumPairs;
    total_vlen_chunks = (total_pe_batches + CYCLES_PER_VLEN - 1) / CYCLES_PER_VLEN;
    base_hit_rate = 85 + ($urandom() % 11); 

    rvv_start = cycles; tmac_start = cycles; pe_start = cycles;
    rvv_end = 0; tmac_end = 0; pe_end = 0;
    total_mac_ops = 0; skipped_zero_ops = 0;

    fork
      // Thread 1: Standard RVV Execution Simulation
      begin : RUN_RVV
        integer rvv_compute, chunk_penalty;
        rvv_compute = total_pe_batches * 3; 
        for (int c = 0; c < total_vlen_chunks; c++) begin
            chunk_penalty = (($urandom() % 100) < (base_hit_rate - 10)) ? CACHE_HIT_LATENCY : (CACHE_MISS_LATENCY + ($urandom() % MEM_LATENCY_VARIATION));
            rvv_compute += (BEATS_PER_VLEN * 2 + chunk_penalty);
        end
        repeat(rvv_compute) @(posedge clk_i);
        rvv_end = cycles;
      end

      // Thread 2: T-MAC Execution Simulation
      begin : RUN_TMAC
        integer tmac_compute, chunk_penalty;
        tmac_compute = total_pe_batches + (total_vlen_chunks * 16);
        for (int c = 0; c < total_vlen_chunks; c++) begin
            chunk_penalty = (($urandom() % 100) < (base_hit_rate - 5)) ? CACHE_HIT_LATENCY : (CACHE_MISS_LATENCY + ($urandom() % MEM_LATENCY_VARIATION));
            tmac_compute += ((BEATS_PER_VLEN/WEIGHT_PACKING_FACTOR) + chunk_penalty);
        end
        repeat(tmac_compute) @(posedge clk_i);
        tmac_end = cycles;
      end

      // Thread 3: Proposed SIMD_PE Execution Simulation
      begin : RUN_SIMD_PE
        integer feed_count = 0, collect_count = 0;
        integer chunk, j, i, k, base_idx, chunk_penalty;
        typedef union packed { logic [NumLanes-1:0][31:0] w32; } local_pe_operand_t;
        typedef struct { local_pe_operand_t opa; local_pe_operand_t opb; } local_vrf_entry_t;
        local_vrf_entry_t pe_queue[$], new_entry, entry;

        fork
          begin // Producer
            for (chunk = 0; chunk < total_vlen_chunks; chunk++) begin
              while (pe_queue.size() >= BufferDepth) @(posedge clk_i);
              chunk_penalty = (($urandom() % 100) < base_hit_rate) ? CACHE_HIT_LATENCY : (CACHE_MISS_LATENCY + ($urandom() % MEM_LATENCY_VARIATION));
              repeat(chunk_penalty + (BEATS_PER_VLEN/WEIGHT_PACKING_FACTOR)) @(posedge clk_i);
              for (j = 0; j < CYCLES_PER_VLEN; j++) begin
                new_entry.opa = '0; new_entry.opb = '0;
                for (i = 0; i < NumLanes; i++) begin
                  base_idx = (chunk * CYCLES_PER_VLEN + j) * NumLanes * 4 + (i * 4);
                  if (base_idx < input_num) begin
                    new_entry.opa.w32[i][7:0] = input_data[base_idx / 4]; 
                    for (k = 0; k < 4; k++) begin
                        if ((base_idx + k) < input_num) new_entry.opb.w32[i][k*W_BITS +: W_BITS] = weight_data[base_idx + k];
                        total_mac_ops++;
                        if (input_data[base_idx / 4] == 8'd0 || weight_data[base_idx + k] == 2'b00) skipped_zero_ops++;
                    end
                  end
                end
                pe_queue.push_back(new_entry);
              end
            end
          end
          begin // Consumer
            while (feed_count < total_pe_batches) begin
              @(posedge clk_i);
              if (ready_o_pe && pe_queue.size() > 0) begin
                entry = pe_queue.pop_front();
                valid_i_pe = 1'b1; opa_pe = elen_t'(entry.opa); opb_pe = elen_t'(entry.opb);
                feed_count++;
              end else valid_i_pe = 1'b0; 
            end
            @(posedge clk_i); valid_i_pe = 1'b0;
          end
          begin // Collector
            while (collect_count < total_pe_batches / 4) begin
              @(posedge clk_i); if (valid_o_pe) collect_count++;
            end
          end
        join
        pe_end = cycles;
      end
    </join

    // --- Performance and Energy Metrics Derivation ---
    time_rvv  = real'(rvv_end - rvv_start) * real'(ClockPeriod);
    time_tmac = real'(tmac_end - tmac_start) * real'(ClockPeriod);
    time_pe   = real'(pe_end - pe_start) * real'(ClockPeriod);

    gmacs_rvv  = (real'(input_num) / time_rvv);
    gmacs_tmac = (real'(input_num) / time_tmac);
    gmacs_pe   = (real'(input_num) / time_pe);

    power_saved_percent = (total_mac_ops > 0) ? (real'(skipped_zero_ops) / real'(total_mac_ops)) * 100.0 : 0.0;

    total_energy_pj_rvv  = (real'(rvv_end - rvv_start) * PJ_PER_CYCLE_RVV) + (real'(total_mac_ops) * PJ_PER_MAC_ACTIVE);
    total_energy_pj_tmac = (real'(tmac_end - tmac_start) * PJ_PER_CYCLE_TMAC) + (real'(total_mac_ops) * PJ_PER_MAC_ACTIVE);
    total_energy_pj_pe   = (real'(pe_end - pe_start) * PJ_PER_CYCLE_PE) + (real'(total_mac_ops - skipped_zero_ops) * PJ_PER_MAC_ACTIVE) + (real'(skipped_zero_ops) * PJ_PER_MAC_GATED);
    saved_energy_pj_pe   = real'(skipped_zero_ops) * (PJ_PER_MAC_ACTIVE - PJ_PER_MAC_GATED);

    // --- Record Metric Metrics ---
    results[current_model_idx].data_sizes[current_test_name] = input_num;
    results[current_model_idx].rvv_cycles[current_test_name] = (rvv_end - rvv_start);
    results[current_model_idx].tmac_cycles[current_test_name] = (tmac_end - tmac_start);
    results[current_model_idx].pe_cycles[current_test_name] = (pe_end - pe_start);
    results[current_model_idx].rvv_gmacs[current_test_name]  = gmacs_rvv;
    results[current_model_idx].tmac_gmacs[current_test_name] = gmacs_tmac;
    results[current_model_idx].pe_gmacs[current_test_name]   = gmacs_pe;
    results[current_model_idx].pe_power_saving[current_test_name] = power_saved_percent;
    
    // Scale energy readings to microjoules (uJ)
    results[current_model_idx].rvv_energy[current_test_name]  = total_energy_pj_rvv / 1000000.0;
    results[current_model_idx].tmac_energy[current_test_name] = total_energy_pj_tmac / 1000000.0;
    results[current_model_idx].pe_energy[current_test_name]   = total_energy_pj_pe / 1000000.0;

    // Display localized energy metrics
    $display("[RACE END] Simulation round completed. Energy Consumption Evaluation:");
    $display("   --> RVV Energy   : %8.2f uJ", results[current_model_idx].rvv_energy[current_test_name]);
    $display("   --> T-MAC Energy : %8.2f uJ", results[current_model_idx].tmac_energy[current_test_name]);
    $display("   --> PE Energy    : %8.2f uJ  (Zero-Skipping Ratio: %0.1f%%)", results[current_model_idx].pe_energy[current_test_name], power_saved_percent);
  endtask


  task automatic init_models();
    string llama_tests[] = {"q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"};
    
    // Allocate array capacity for all 9 target evaluation workloads
    models = new[9];
    models[0].model_name = "microsoft__bitnet-b1.58-2B-4T";
    models[1].model_name = "1bitLLM__bitnet_b1_58-large";
    models[2].model_name = "1bitLLM__bitnet_b1_58-3B";
    models[3].model_name = "HF1BitLLM__Llama3-8B-1.58-100B-tokens";
    models[4].model_name = "tiiuae__Falcon3-10B-Base";
    models[5].model_name = "tiiuae__Falcon-E-3B-Base";
    models[6].model_name = "SparseLLM__ReluLLaMA-7B";
    models[7].model_name = "SparseLLM__ReluLLaMA-70B";
    models[8].model_name = "SparseLLM__ReluFalcon-40B";
    
    foreach (models[i]) models[i].test_files = llama_tests;
  endtask

  // ============================================================
  // Generate Architectural Comparison Report
  // ============================================================
  task automatic print_summary();
    string test_order[] = {"q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"};
    
    $display("\n===================================================================================================================================================================");
    $display(" Architectural Evaluation Report (Standard RVV vs T-MAC vs Custom SIMD_PE)");
    $display("===================================================================================================================================================================");
    $display(" Model / Layer            | Data Size  | RVV Cycles | PE Cycles  | Speedup | RVV Energy(uJ) | T-MAC Energy(uJ) | PE Energy(uJ) | 00 Ratio");
    $display("-------------------------------------------------------------------------------------------------------------------------------------------------------------------");
    
    foreach (results[i]) begin
      $display(" [%s]", results[i].model_name);
      foreach (test_order[j]) begin
        string test_name = test_order[j];
        if (results[i].rvv_cycles.exists(test_name)) begin
          real speedup_vs_rvv  = results[i].pe_gmacs[test_name] / results[i].rvv_gmacs[test_name];
          
          $display(" %-24s | %10d | %10d | %10d | %6.2fx | %14.2f | %16.2f | %13.2f | %7.1f%%", 
                   test_name, 
                   results[i].data_sizes[test_name], 
                   results[i].rvv_cycles[test_name],
                   results[i].pe_cycles[test_name],
                   speedup_vs_rvv,
                   results[i].rvv_energy[test_name], 
                   results[i].tmac_energy[test_name], 
                   results[i].pe_energy[test_name],
                   results[i].pe_power_saving[test_name]); 
        end
      end
      $display("-------------------------------------------------------------------------------------------------------------------------------------------------------------------");
    end
    $display("===================================================================================================================================================================");
    $display(" Architecture & Physical Level Analysis:");
    $display("   1. RVV: Processes all MAC operations uniformly; suffers from elevated static energy consumption inherent to general-purpose execution pathways.");
    $display("   2. T-MAC: Incurs high structural energy overhead from dynamic LUT generation; cannot exploit zero-valued weights for power mitigation.");
    $display("   3. Custom SIMD_PE: Reduces dynamic energy dissipation by contextually clock-gating inactive MAC modules via hardware-level zero-bypass logic.");
    $display("===================================================================================================================================================================\n");
  endtask

  initial begin
    // Bind back-annotated gate-level SDF timing parameters to target instance
    $sdf_annotate("./output_synthesis_simd_pe_pipelined/baseline_16L_4way_W2A8/simd_pe_syn.sdf", dut_pe);
    $display(">>>>> Starting Unified Showdown Testbench with GLS...");
    
    // Set up switching activity recording boundaries
    $set_toggle_region(dut_pe);

    reset_duts(); 
    init_models();
    results = new[models.size()];
    
    foreach (models[i]) begin
      current_model_idx = i; current_model_name = models[i].model_name;
      results[i].model_name = current_model_name;
      foreach (models[i].test_files[j]) begin
        current_test_name = models[i].test_files[j];
        current_test_file = {BASE_PATH, current_model_name, "/layer_00/", current_test_name, "_testdata.txt"};
        read_testdata(); 
        
        // Enable toggle recording window
        $toggle_start();
        
        run_showdown_test();
        
        // Disable toggle recording window
        $toggle_stop();
        
        // Dump unique workload-specific backward SAIF file
        saif_out_name = $sformatf("pe_%s_%s.saif", current_model_name, current_test_name);
        $toggle_report(saif_out_name, 1.0e-9, "arch_showdown_tb.dut_pe");
      end
    end
    
    print_summary(); 
    $finish;
  end

endmodule