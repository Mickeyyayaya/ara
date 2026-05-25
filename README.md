# TETRA: An Efficient RISC-V ISA Extension for Mixed-Precision LLM Inference

[![ci](https://github.com/pulp-platform/ara/actions/workflows/ci.yml/badge.svg)](https://github.com/pulp-platform/ara/actions/workflows/ci.yml)

TETRA (Two-bit Efficient Tensor RISC-V Acceleration) is an advanced vector unit working as a coprocessor for the CVA6 core. It supports the RISC-V Vector Extension, version 1.0, while integrating specialized microarchitectural modifications to accelerate mixed-precision Large Language Model (LLM) inference.

Prototypical documentation can be found at https://pulp-platform.github.io/ara

---

## Hardware Architecture & Microarchitecture

This branch introduces custom modifications to the vector lanes, execution units, and decoding pipelines of the baseline vector processor to support highly efficient sub-byte tensor operations.

### Modified Files Log

The following files contain our custom architectural modifications, custom SIMD pipelines, or evaluation wrappers:

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

### Core Architectural Features

#### 1. Sub-Byte Weight Packing vs. Standard RVV Padding

In traditional RISC-V Vector (RVV) implementations using `SEW=8`, executing lower bit-width values (such as 2-bit weights) requires padding the remaining bits via sign extension, causing up to 75% memory and bandwidth waste. TETRA implements sub-byte packing, storing four independent 2-bit weights directly inside a single 8-bit element block to optimize memory footprint and register utilization.

#### 2. High-Efficiency MUX-Based Processing Element (PE)

To replace power-heavy conventional multipliers, TETRA integrates a shift-and-add lookahead architecture within `simd_pe.sv`. The 2-bit weight data map straight onto a 4-to-1 Multiplexer selection table:

| Weight (2-bit) | Output | Example ($A=5$) | Hardware Implementation Blueprint |
| --- | --- | --- | --- |
| `00` | $0$ | $0$ | Triggers Zero-Skipping Pipeline |
| `01` | $A$ | $5$ | Extends / Passes Sign-Extended Activation $A$ |
| `10` | $A \times 2$ | $10$ | 0-delay hardwired Left Shift 1 ($\ll 1$) |
| `11` | $A \times 3$ | $15$ | Invokes low-area Adder unit ($1A + 2A$) |

#### 3. Two-Level Zero-Skipping Gating (Power Saving)

To exploit value sparsity during LLM processing, TETRA incorporates a dual hardware-gating framework:

* **Activation Zero Gating:** A dedicated Zero Detector continuously screens the incoming 8-bit signed activation ($A_{in}$). If $A_{in} == 0$, the `mul_enable` signal drops to low, immediately gating off downstream switching paths.
* **Weight Zero Gating:** When a packed 2-bit segment matches `00`, the 4-to-1 MUX selects ground, bypassing execution toggles to minimize dynamic power dissipation.

### Evaluation & Performance Results

#### 1. Silicon Area Reduction

By swapping complex multipliers for hardwired MUX-based lookahead logic, TETRA significantly minimizes area overhead compared to full RVV execution baselines (such as RVV-EW8, RVV-EW16, RVV-EW32, RVV-EW64) and advanced alternatives like T-MAC.

#### 2. Clock Cycle Speedup on LLM Topologies

Evaluated across diverse large language model and transformer workloads (including Llama3-8B, Falcon variants, and various Sparse configurations), TETRA delivers a massive reduction in total execution cycle counts, achieving an **overall average performance speedup of ~3.86x** compared to standard RVV systems.

---

## Dependencies

Check `DEPENDENCIES.md` for a list of hardware and software dependencies of TETRA.

## Supported instructions

Check `FUNCTIONALITIES.md` to check which instructions are currently supported by TETRA.

## Get started

Make sure you clone this repository recursively to get all the necessary submodules:

```bash
make git-submodules

```

If the repository path of any submodule changes, run the following command to change your submodule's pointer to the remote repository:

```bash
git submodule sync --recursive

```

## Toolchain Setup

TETRA requires a RISC-V LLVM toolchain capable of understanding the vector extension, version 1.0.
To build this toolchain, run the following command in the project's root directory:

```bash
# Build the LLVM toolchain
make toolchain-llvm

```

TETRA also requires an updated Spike ISA simulator, with support for the vector extension.
There are linking issues with the standard libraries when using newer CC/CXX versions to compile Spike. Therefore, here we resort to older versions of the compilers. If there are problems with dynamic linking, use:
`make riscv-isa-sim LDFLAGS="-static-libstdc++"`. Spike was compiled successfully using gcc and g++ version 7.2.0.

To build Spike, run the following command in the project's root directory:

```bash
# Build Spike
make riscv-isa-sim

```

## Verilator Compiler

TETRA requires an updated version of Verilator for RTL simulations.
To build it, run the following command in the project's root directory:

```bash
# Build Verilator
make verilator

```

## Configuration

TETRA's parameters are centralized in the `config` folder, which provides several configurations to the vector machine. Please check `config/README.md` for more details.

Prepend `config=chosen_tetra_configuration` to your Makefile commands, or export the `ARA_CONFIGURATION` variable to choose a configuration other than the `default` one.

---

## Software Flow

### Build Applications

The `apps` folder contains example applications that work on TETRA. Run the following command to build an application. E.g., `hello_world`:

```bash
cd apps
make bin/hello_world

```

### SPIKE Simulation

All the applications can be simulated with SPIKE. Run the following command to build and run an application. E.g., `hello_world`:

```bash
cd apps
make bin/hello_world.spike
make spike-run-hello_world

```

### RISC-V Tests

The `apps` folder also contains the RISC-V tests repository, including a few unit tests for the vector instructions. Run the following command to build the unit tests:

```bash
cd apps
make riscv_tests

```

---

## RTL Simulation, Synthesis, & Evaluation Flow

All hardware simulation, verification, and synthesis tasks should be executed inside the `hardware/` directory.

### Workflow 1: Standard Verification Flow

To run the baseline verification flow using standard binaries compiled from the `apps/` directory:

```bash
cd hardware
# Initialize hardware IP dependencies via Bender and apply Verilator patches
make checkout
make apply-patches

# Verilate the RTL design
make verilate

# Execute the RISC-V unit test suite
make riscv_tests_simv

```

### Workflow 2: Custom Simulation, Synthesis & Power Evaluation

Because the toolchains and test vectors for our custom features have been decoupled, use the following execution sequence to evaluate hardware performance, area, and power metrics.

#### Step 1: Generate Custom Test Vectors

Run the Python data generator script to create the required inputs and golden outputs for the hardware testbench:

```bash
cd hardware/src/lane
python generatedata.py

```

#### Step 2: Compile the Showdown Environment

Execute the build script to compile the specialized simulation environment:

```bash
./build_all.sh

```

#### Step 3: Run Simulation & Capture Activity Traces

Run the generated simulation executable (`simv_showdown`). This execution performs verification and dumps the **Gate-Level Simulation (GLS)** files alongside the **SAIF (Switching Activity Interchange Format)** file required for power analysis:

```bash
./simv_showdown

```

#### Step 4: RTL Synthesis via Synopsys Design Compiler

Use Synopsys Design Compiler (DC) to synthesize the custom arithmetic units. Run the following three scripts to generate the gate-level netlists and extract area/timing reports:

```bash
dc_shell -f synthesis_simd_mul.tcl
dc_shell -f synthesis_simd_pe.tcl
dc_shell -f synthesis_tmac.tcl

```

#### Step 5: Power Analysis

To obtain the final power consumption metrics, feed the post-GLS switching activity back into Design Compiler using the dedicated power script:

```bash
dc_shell -f run_dc_power.tcl

```

---

## Advanced Simulation Options

### Waveform Traces

Add `trace=1` to the `verilate`, `simv`, and `riscv_tests_simv` commands to generate waveform traces in the `fst` format. You can use `gtkwave` to open such waveforms.

### Ideal Dispatcher Mode

CVA6 can be replaced by an ideal FIFO that dispatches the vector instructions to TETRA with the maximum issue-rate possible. In this mode, only TETRA and its memory system affect performance.

To compile a program and generate its vector trace:

```bash
cd apps
make bin/${program}.ideal

```

To run the system in Ideal Dispatcher mode:

```bash
cd hardware
make sim app=${program} ideal_dispatcher=1

```

### VCD Dumping

It's possible to dump VCD files for accurate activity-based power analyses. To do so, use the `vcd_dump=1` option to compile the program and to run the simulation:

```bash
make -C apps bin/${program} vcd_dump=1
make -C hardware simc app=${program} vcd_dump=1

```

Currently, the following kernels support automatic VCD dumping: `fmatmul`, `fconv3d`, `fft`, `dwt`, `exp`, `cos`, `log`, `dropout`, `jacobi2d`.

### Linting Flow

We also provide Synopsys Spyglass linting scripts in `hardware/spyglass`. Run `make lint` in the hardware folder, with a specific MemPool configuration, to run the tests associated with the `lint_rtl` target.

### Support for `rvv-bench`

To run `rvv-bench` instructions benchmark, execute:

```bash
make rvv-bench
make -C apps bin/rvv
make -C hardware simv app=rvv

```

---

## FPGA Implementation and Linux Flow

TETRA supports Cheshire's FPGA flow and can be currently implemented on VCU128 and VCU118 in bare-metal and with Linux. The tested configuration is with 2 lanes. For information about the FPGA bare-metal and Linux flows, please refer to `cheshire/README.md`.

---

## Publications & Citations

If you use TETRA or its underlying architecture in your research, please cite the corresponding publications:

```bibtex
@Mastersthesis{Tetra2026,
  author  = {Chiang, Chih-tuan},
  title   = {TETRA: An Efficient RISC-V ISA Extension for Mixed-Precision LLM Inference},
  school  = {National Yang Ming Chiao Tung University (NYCU)},
  year    = {2026}
}

@Article{Ara2020,
  author  = {Matheus Cavalcante and Fabian Schuiki and Florian Zaruba and Michael Schaffner and Luca Benini},
  journal = {IEEE Transactions on Very Large Scale Integration (VLSI) Systems},
  title   = {Ara: A 1-GHz+ Scalable and Energy-Efficient RISC-V Vector Processor With Multiprecision Floating-Point Support in 22-nm FD-SOI},
  year    = {2020},
  volume  = {28},
  number  = {2},
  pages   = {530-543},
  doi     = {10.1109/TVLSI.2019.2950087}
}

@Inproceedings{Ara2022,
  author    = {Perotti, Matteo and Cavalcante, Matheus and Wistoff, Nils and Andri, Renzo and Cavigelli, Lukas and Benini, Luca},
  booktitle = {2022 IEEE 33rd International Conference on Application-specific Systems, Architectures and Processors (ASAP)},
  title     = {A “New Ara” for Vector Computing: An Open Source Highly Efficient RISC-V V 1.0 Vector Processor Design},
  year      = {2022},
  pages     = {43-51},
  doi       = {10.1109/ASAP54787.2022.00017}
}

@Article{Ara22024,
  author  = {Perotti, Matteo and Cavalcante, Matheus and Andri, Renzo and Cavigelli, Lukas and Benini, Luca},
  journal = {IEEE Transactions on Computers},
  title   = {Ara2: Exploring Single- and Multi-Core Vector Processing With an Efficient RVV 1.0 Compliant Open-Source Processor},
  year    = {2024},
  volume  = {73},
  number  = {7},
  pages   = {1822-1836},
  doi     = {10.1109/TC.2024.3388896}
}
