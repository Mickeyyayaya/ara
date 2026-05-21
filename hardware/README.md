# Ara Hardware Design & Evaluation Flow

This directory contains the SystemVerilog RTL source codes, simulation targets, and synthesis scripts for Ara. This specific branch introduces custom modifications to the vector lanes and decoding pipelines to integrate specialized Processing Elements (PEs).

## Modified Files Log

The following files contain custom architecture modifications, custom SIMD pipelines, or evaluation wrappers:

```text
hardware/include/
├── ara_pkg.sv
└── rvv_pkg.sv

hardware/src/
├── accel_dispatcher_ideal.sv
├── ara.sv
├── ara_dispatcher.sv
├── ara_sequencer.sv
├── ara_soc.sv
├── ara_system.sv
└── cva6_accel_first_pass_decoder.sv

hardware/src/lane/
├── POWER_GATING_GENERIC.mr
├── acc_pkg.pvk
├── ara_pkg.pvk
├── arch_showdown_tb.sv
├── build_all.sh
├── config_pkg.pvk
├── custom_pe_wrapper.sv
├── cva6_config_pkg.pvk
├── generatedata.py
├── helper_modules.sv
├── lane.sv
├── lane_sequencer.sv
├── operand_queues_stage.sv
├── operand_requester.sv
├── power_gating_generic-verilog.pvl
├── power_gating_generic-verilog.syn
├── power_gating_generic.sv
├── rvv_pkg.pvk
├── simd_alu.sv
├── simd_mul.sv
├── simd_pe.sv
├── simd_tmac.sv
├── synthesis_simd_mul.tcl
├── synthesis_simd_pe.tcl
├── synthesis_tmac.tcl
└── vector_fus_stage.sv
└── vmfpu.sv
```

---

## Workflow 1: Standard Verification Flow

To run the baseline verification flow using standard binaries compiled from the `apps/` directory:

```bash
# 1. Initialize hardware IP dependencies via Bender and apply Verilator patches
make checkout
make apply-patches

# 2. Verilate the RTL design
make verilate

# 3. Execute the RISC-V unit test suite
make riscv_tests_simv
```

---

## Workflow 2: Custom Simulation, Synthesis & Power Evaluation

Because the toolchains and test vectors for our custom features have been decoupled, use the following execution sequence to evaluate hardware performance, area, and power metrics.

### Step 1: Generate Custom Test Vectors
Run the Python data generator script to create the required inputs and golden outputs for the hardware testbench:
```bash
cd src/lane
python generatedata.py
```

### Step 2: Compile the Showdown Environment
Execute the build script to compile the specialized simulation environment:
```bash
./build_all.sh
```

### Step 3: Run Simulation & Capture Activity Traces
Run the generated simulation executable (`simv_showdown`). This execution performs verification and dumps the **Gate-Level Simulation (GLS)** files alongside the **SAIF (Switching Activity Interchange Format)** file required for power analysis:
```bash
./simv_showdown
```

### Step 4: RTL Synthesis via Synopsys Design Compiler
Use Synopsys Design Compiler (DC) to synthesize the custom arithmetic units. Run the following three scripts to generate the gate-level netlists and extract area/timing reports:
```bash
dc_shell -f synthesis_simd_mul.tcl
dc_shell -f synthesis_simd_pe.tcl
dc_shell -f synthesis_tmac.tcl
```

### Step 5: Power Analysis
To obtain the final power consumption metrics, feed the post-GLS switching activity back into Design Compiler using the dedicated power script:
```bash
dc_shell -f run_dc_power.tcl
```
Following this step, your final reports regarding area, timing, and power will be completely generated.